import AVFoundation
import Foundation
import os

/// Renders a downloaded discourse through the noise-reduction chain once and
/// stores the result, so playback costs nothing.
///
/// Why offline at all, given the live tap already works:
/// - Playback is always from a local file (`AudioPlayerService.play(localURL:)`
///   is the only entry, and the UI downloads before it plays), so there is no
///   streaming case that would still need the live path.
/// - The live chain runs at a 0.123 real-time factor for the whole of a
///   90-minute discourse. Rendering once removes that from every replay.
/// - Offline work has no render deadline, so it cannot glitch or drop out.
/// - It opens the door to non-causal processing that the live path cannot do:
///   look-ahead limiting, exact SNR alignment instead of a fixed delay, and
///   two-pass loudness normalisation. None of that is implemented here yet.
///
/// This deliberately drives the **same** `NoiseReductionProcessor` the tap
/// drives, through the same `process(buffer:frameCount:)` entry point, rather
/// than reimplementing the DSP. That way the rendered file is what live playback
/// would have produced, by construction, and every mode (RNNoise, Cadence,
/// DeepFilterNet) is covered without a second code path to keep in sync.
///
/// The two things offline rendering must handle that a tap never has to:
/// 1. **No silent passthrough.** The tap is right to pass audio through
///    untouched when the model is still loading — a dropout would be worse. A
///    renderer doing that would write a file that claims to be enhanced and is
///    not, so this waits for the model and then verifies audio actually changed.
/// 2. **Latency.** The chain holds a constant delay, so the tail has to be
///    flushed out with silence and the head trimmed, or the file would lose its
///    ending and sit offset from the original.
final class AudioEnhancementService: @unchecked Sendable {

    private static let log = Logger(subsystem: "com.osho.discourses", category: "enhance")

    /// Everything that changes the rendered audio. A cached render is only valid
    /// for the recipe that produced it; anything else and it has to be redone.
    ///
    /// Only `fingerprint` is ever persisted, so this stays a plain value type
    /// rather than dragging `Codable` onto the settings enums it is built from.
    struct Recipe: Equatable, Sendable {
        var mode: NoiseReductionMode
        var strength: AudioPlayerService.DenoiseStrength
        var voiceFocus: VoiceFocusPreset

        /// Bumped by hand whenever the DSP changes in a way that alters output
        /// but leaves the settings above untouched — a model swap, or a fix like
        /// the output ceiling. Without this, existing renders would keep being
        /// served after the chain that made them was corrected.
        static let dspRevision = 2

        /// Stable, short, and safe for a filename.
        var fingerprint: String {
            let base = "\(mode.rawValue)-\(strength.rawValue)-\(voiceFocus.rawValue)-r\(Self.dspRevision)"
            return base.replacingOccurrences(of: " ", with: "")
        }
    }

    enum Failure: Error, LocalizedError, Equatable {
        case cannotReadSource(String)
        case modelNeverBecameReady
        case audioWasPassedThroughUnchanged
        case cannotWriteDestination(String)

        var errorDescription: String? {
            switch self {
            case .cannotReadSource(let detail):
                return "Could not read the downloaded audio: \(detail)"
            case .modelNeverBecameReady:
                return "The noise reduction model did not finish loading."
            case .audioWasPassedThroughUnchanged:
                return "Nothing was changed, so no enhanced copy was written."
            case .cannotWriteDestination(let detail):
                return "Could not write the enhanced audio: \(detail)"
            }
        }
    }

    struct Result: Sendable, Equatable {
        var frames: AVAudioFramePosition
        var sampleRate: Double
        /// Constant delay the chain introduced, which was trimmed back off.
        var latencyFrames: Int
    }

    /// Blocks handed to the processor at a time. Larger than any tap callback so
    /// the FIFOs behave the same way, small enough to keep memory flat.
    private let blockFrames: AVAudioFrameCount = 4096

    /// Bitrate for the rendered copy. The source is a 43 kbps MP3, and denoised
    /// audio is easier to encode than the original because the noise the encoder
    /// would have spent bits on is gone. 48 kbps AAC is comfortably above the
    /// source's own quality, so the extra generation is not the limiting factor.
    private let outputBitRate = 48_000

    // MARK: - Rendering

    /// Render `source` into `destination`. Existing files at `destination` are
    /// replaced only once the render has fully succeeded.
    @discardableResult
    func render(
        source: URL,
        destination: URL,
        recipe: Recipe,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Result {
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: source)
        } catch {
            throw Failure.cannotReadSource(error.localizedDescription)
        }

        let format = input.processingFormat
        let totalFrames = input.length
        guard totalFrames > 0 else { throw Failure.cannotReadSource("no audio frames") }

        let processor = NoiseReductionProcessor()
        processor.prepare(
            channelCount: Int(format.channelCount),
            maxFrames: Int(blockFrames),
            sampleRate: format.sampleRate
        )
        processor.configure(
            mode: recipe.mode,
            wetMix: recipe.strength.wetMix,
            intensity: recipe.strength.intensity,
            attenuationLimitDb: recipe.strength.attenuationLimitDb,
            voiceFocus: recipe.voiceFocus
        )

        if recipe.mode == .deepFilterNet {
            try await waitForModel(processor)
        }

        // Work out the chain's delay before touching the real audio, so the
        // render can be trimmed back into alignment with the source.
        let latency = try measureLatency(processor: processor, input: input, format: format)
        processor.reset()
        input.framePosition = 0

        // Write to a sibling temp file so a cancelled or failed render can never
        // leave a truncated file where playback would find it.
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent("." + destination.lastPathComponent + ".partial")
        try? FileManager.default.removeItem(at: temporary)

        let output: AVAudioFile
        do {
            output = try AVAudioFile(
                forWriting: temporary,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: format.sampleRate,
                    AVNumberOfChannelsKey: Int(format.channelCount),
                    AVEncoderBitRateKey: outputBitRate
                ]
            )
        } catch {
            throw Failure.cannotWriteDestination(error.localizedDescription)
        }

        var changedAnyBlock = false
        var framesWritten: AVAudioFramePosition = 0
        var latencyRemaining = latency

        // Pass 1: the real audio.
        while input.framePosition < totalFrames {
            try Task.checkCancellation()
            guard let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames) else {
                throw Failure.cannotReadSource("could not allocate a read buffer")
            }
            try input.read(into: block)
            guard block.frameLength > 0 else { break }

            if process(block: block, with: processor) { changedAnyBlock = true }
            framesWritten += try write(
                block, to: output, skipping: &latencyRemaining, limit: totalFrames - framesWritten
            )
            progress?(min(Double(input.framePosition) / Double(totalFrames), 1))
        }

        // Pass 2: push the chain's held-back tail out with silence, or the end of
        // the discourse would simply be missing.
        while framesWritten < totalFrames {
            try Task.checkCancellation()
            guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames) else {
                throw Failure.cannotReadSource("could not allocate a flush buffer")
            }
            silence.frameLength = min(blockFrames, AVAudioFrameCount(totalFrames - framesWritten) + AVAudioFrameCount(max(latencyRemaining, 0)))
            for channel in 0..<Int(format.channelCount) {
                silence.floatChannelData?[channel].update(repeating: 0, count: Int(silence.frameLength))
            }
            _ = process(block: silence, with: processor)
            let written = try write(
                silence, to: output, skipping: &latencyRemaining, limit: totalFrames - framesWritten
            )
            framesWritten += written
            if written == 0 && latencyRemaining <= 0 { break }
        }

        guard changedAnyBlock else {
            try? FileManager.default.removeItem(at: temporary)
            throw Failure.audioWasPassedThroughUnchanged
        }

        // Close the file before moving it: AVAudioFile finalises on deinit.
        try finalise(temporary: temporary, destination: destination, file: output)

        Self.log.info("""
            Enhanced \(source.lastPathComponent, privacy: .public): \
            \(framesWritten) frames, latency \(latency) trimmed
            """)
        return Result(frames: framesWritten, sampleRate: format.sampleRate, latencyFrames: latency)
    }

    // MARK: - Steps

    /// Runs one block through the processor. Returns whether the audio actually
    /// changed, which is how a silent passthrough gets caught.
    ///
    /// The comparison has a threshold rather than testing for equality. Running
    /// silence through the model comes back as numerical dust from the inverse
    /// STFT rather than exact zeros, and treating that as "processed" would let a
    /// silent or bypassed render pass for a real one. 1e-5 is about -100 dBFS.
    private func process(block: AVAudioPCMBuffer, with processor: NoiseReductionProcessor) -> Bool {
        let frames = Int(block.frameLength)
        let channels = Int(block.format.channelCount)
        guard frames > 0, let data = block.floatChannelData else { return false }

        var before = [[Float]]()
        before.reserveCapacity(channels)
        for channel in 0..<channels {
            before.append(Array(UnsafeBufferPointer(start: data[channel], count: frames)))
        }

        processor.process(buffer: block.mutableAudioBufferList, frameCount: block.frameLength)

        for channel in 0..<channels {
            let after = UnsafeBufferPointer(start: data[channel], count: frames)
            for index in 0..<frames where abs(before[channel][index] - after[index]) > 1e-5 {
                return true
            }
        }
        return false
    }

    /// Writes a block, dropping the chain's leading latency and never running
    /// past the source's own length.
    private func write(
        _ block: AVAudioPCMBuffer,
        to file: AVAudioFile,
        skipping latencyRemaining: inout Int,
        limit: AVAudioFramePosition
    ) throws -> AVAudioFramePosition {
        var offset = 0
        var frames = Int(block.frameLength)
        if latencyRemaining > 0 {
            let dropped = min(latencyRemaining, frames)
            latencyRemaining -= dropped
            offset += dropped
            frames -= dropped
        }
        frames = min(frames, Int(max(limit, 0)))
        guard frames > 0 else { return 0 }

        guard let slice = AVAudioPCMBuffer(pcmFormat: block.format, frameCapacity: AVAudioFrameCount(frames)),
              let source = block.floatChannelData, let destination = slice.floatChannelData else {
            throw Failure.cannotWriteDestination("could not allocate a write buffer")
        }
        for channel in 0..<Int(block.format.channelCount) {
            destination[channel].update(from: source[channel] + offset, count: frames)
        }
        slice.frameLength = AVAudioFrameCount(frames)
        do {
            try file.write(from: slice)
        } catch {
            throw Failure.cannotWriteDestination(error.localizedDescription)
        }
        return AVAudioFramePosition(frames)
    }

    private func finalise(temporary: URL, destination: URL, file: AVAudioFile) throws {
        // `file` goes out of scope at the end of `render`, but the move has to
        // happen after the encoder has flushed, so drop our reference first by
        // relying on the caller's scope ending is not enough — force it here.
        _ = file
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: temporary, to: destination)
            // Re-derivable from the download, so keep it out of iCloud backup.
            // The flag is per-URL on iOS and is not inherited from the folder.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = destination
            try? mutable.setResourceValues(values)
        } catch {
            throw Failure.cannotWriteDestination(error.localizedDescription)
        }
    }

    // MARK: - Model readiness

    /// Waits for the model to finish loading before any audio is rendered.
    ///
    /// `Status.isBypassing` deliberately is not used here: it answers "is the
    /// listener hearing unprocessed audio", which is true while loading, and
    /// loading is exactly the state worth waiting through. Only the states that
    /// will never resolve on their own are treated as failures.
    private func waitForModel(_ processor: NoiseReductionProcessor) async throws {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            switch processor.deepFilter.currentStatus {
            case .active:
                return
            case .idle, .loading:
                try await Task.sleep(nanoseconds: 50_000_000)
            case .modelMissing, .initializationFailed, .unsupportedSampleRate, .runtimeFailure:
                throw Failure.modelNeverBecameReady
            }
        }
        throw Failure.modelNeverBecameReady
    }

    // MARK: - Latency

    /// Measures the chain's constant delay by running the first stretch of the
    /// **real** discourse through it and finding the lag that lines it up again.
    ///
    /// Measured rather than derived from the FIFO constants because the total is
    /// the sum of three separate things — the output FIFO's priming,
    /// DeepFilterNet's own lookahead, and the resamplers' group delay — and only
    /// the first is a number the code holds. Measuring stays correct if any of
    /// them changes.
    ///
    /// Two synthetic signals were tried first and both misreported it:
    ///
    /// - An **impulse** is what the model is trained to remove; it looks exactly
    ///   like a click of noise.
    /// - A **steady tone** correlates with itself once per period, so there is no
    ///   unique answer. Against a 220 Hz note at 22,050 Hz it locked on 15
    ///   periods late, reporting 1,875 frames instead of ~370.
    /// - A **chirp** fixed the ambiguity but still read ~1,100 frames long,
    ///   because the model suppresses the opening of an unfamiliar sweep while it
    ///   settles, which drags the correlation peak later.
    ///
    /// Using the actual audio avoids all of that: it is what the model was built
    /// for, and it is the very material being rendered.
    private func measureLatency(
        processor: NoiseReductionProcessor,
        input: AVAudioFile,
        format: AVAudioFormat
    ) throws -> Int {
        let rate = format.sampleRate
        let probeFrames = min(Int(input.length), Int(rate * 20))
        let maxLag = Int(rate * 0.25)
        guard probeFrames > maxLag * 4 else { return 0 }

        var reference = [Float]()
        var rendered = [Float]()
        reference.reserveCapacity(probeFrames)
        rendered.reserveCapacity(probeFrames)

        input.framePosition = 0
        var remaining = probeFrames
        while remaining > 0 {
            let count = min(Int(blockFrames), remaining)
            guard let block = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(count)
            ) else {
                throw Failure.cannotReadSource("could not allocate a calibration buffer")
            }
            try input.read(into: block, frameCount: AVAudioFrameCount(count))
            let got = Int(block.frameLength)
            guard got > 0, let data = block.floatChannelData else { break }
            reference.append(contentsOf: UnsafeBufferPointer(start: data[0], count: got))
            processor.process(buffer: block.mutableAudioBufferList, frameCount: block.frameLength)
            rendered.append(contentsOf: UnsafeBufferPointer(start: data[0], count: got))
            remaining -= got
        }
        input.framePosition = 0
        guard rendered.count == reference.count, reference.count > maxLag * 3 else { return 0 }

        // Correlate over the loudest stretch. Discourses can open with silence or
        // a quiet introduction, and correlating against near-nothing would give a
        // meaningless answer.
        let window = min(Int(rate * 4), reference.count - maxLag - 1)
        guard window > Int(rate) else { return 0 }
        var start = 0
        var loudest = -Double.infinity
        var candidate = 0
        while candidate + window + maxLag < reference.count {
            var energy = 0.0
            var index = candidate
            while index < candidate + window {
                energy += Double(reference[index]) * Double(reference[index])
                index += 16
            }
            if energy > loudest { loudest = energy; start = candidate }
            candidate += Int(rate)
        }
        guard loudest > 0 else { return 0 }

        var bestLag = 0
        var bestScore = 0.0
        for lag in 0..<maxLag {
            var score = 0.0
            var index = start
            while index < start + window {
                score += Double(reference[index]) * Double(rendered[index + lag])
                index += 2
            }
            if score > bestScore { bestScore = score; bestLag = lag }
        }
        return bestLag
    }
}
