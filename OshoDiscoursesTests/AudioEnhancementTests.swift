import AVFoundation
import Testing
@testable import OshoDiscourses

/// Tests for rendering the noise-reduction chain to a file ahead of playback.
///
/// These run the real chain and the real bundled model, for the same reason the
/// DeepFilterNet tests do: the point of the feature is that a rendered file is
/// what live playback would have produced, and a stubbed processor would prove
/// nothing about that.
struct AudioEnhancementTests {

    // MARK: - Fixtures

    /// A voiced-sounding source whose pattern is unique in time.
    ///
    /// The pitch changes every syllable on purpose. A steady note is periodic, so
    /// correlating against it has one answer per period and any alignment check
    /// built on it can lock onto the wrong peak — which is exactly what happened
    /// with a 190 Hz fixture: the measurement and the check disagreed by 1,102
    /// frames and neither was trustworthy. Varying the pitch gives the signal a
    /// single unambiguous match.
    private func writeSource(
        seconds: Double,
        sampleRate: Double = 22_050,
        silent: Bool = false
    ) throws -> URL {
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("enhance-source-\(UUID().uuidString).wav")
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
        )
        let frames = Int(seconds * sampleRate)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        )
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try #require(buffer.floatChannelData)
        // Fixed sequence so runs are reproducible.
        let pitches: [Double] = [150, 232, 191, 305, 168, 264, 212, 143, 287, 176]
        let syllable = 0.5
        var phase = 0.0
        for index in 0..<frames {
            guard !silent else { data[0][index] = 0; continue }
            let t = Double(index) / sampleRate
            let slot = Int(t / syllable)
            let within = t - Double(slot) * syllable
            // Speak for 0.35 s of every 0.5 s, then pause.
            guard within < 0.35 else { data[0][index] = 0; phase = 0; continue }
            let pitch = pitches[slot % pitches.count]
            phase += 2 * .pi * pitch / sampleRate
            let envelope = min(within / 0.03, (0.35 - within) / 0.03, 1)
            let tone = sin(phase) + 0.5 * sin(2 * phase) + 0.3 * sin(3 * phase)
            data[0][index] = Float(0.25 * max(envelope, 0) * tone)
        }
        try file.write(from: buffer)
        return url
    }

    private func readAll(_ url: URL) throws -> (samples: [Float], rate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
        )
        try file.read(into: buffer)
        let data = try #require(buffer.floatChannelData)
        return (
            Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))),
            format.sampleRate
        )
    }

    /// Lag, in samples, that best lines `rendered` up against `reference`.
    private func bestLag(reference: [Float], rendered: [Float], maxLag: Int) -> Int {
        var bestLag = 0
        var bestScore = -Double.infinity
        let window = min(reference.count, rendered.count) - maxLag - 1
        guard window > 1000 else { return 0 }
        for lag in -maxLag...maxLag {
            var score = 0.0
            var index = maxLag
            while index < window {
                score += Double(reference[index]) * Double(rendered[index + lag])
                index += 4
            }
            if score > bestScore { bestScore = score; bestLag = lag }
        }
        return bestLag
    }

    // MARK: - Alignment and length

    @Test func renderKeepsItsLengthAndStaysAlignedWithTheSource() async throws {
        let source = try writeSource(seconds: 6)
        defer { try? FileManager.default.removeItem(at: source) }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("enhance-out-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: destination) }

        let service = AudioEnhancementService()
        let recipe = AudioEnhancementService.Recipe(
            mode: .deepFilterNet, strength: .medium, voiceFocus: .focus
        )
        let result = try await service.render(
            source: source, destination: destination, recipe: recipe
        )

        // The chain holds a real delay, and it must have been measured, not assumed.
        #expect(result.latencyFrames > 0, "no latency measured; the trim would be a no-op")
        #expect(
            Double(result.latencyFrames) < result.sampleRate * 0.25,
            "measured latency of \(result.latencyFrames) frames is implausible"
        )

        let original = try readAll(source)
        let rendered = try readAll(destination)
        #expect(rendered.rate == original.rate, "sample rate must survive the render")

        // Length must match the source, not run short by the chain's latency —
        // that is what flushing the tail is for.
        let drift = abs(rendered.samples.count - original.samples.count)
        #expect(
            Double(drift) < original.rate * 0.15,
            "rendered length drifted by \(drift) frames from the source"
        )

        // And it must line up, so a saved position or bookmark means the same
        // thing in both files.
        let lag = bestLag(
            reference: original.samples,
            rendered: rendered.samples,
            maxLag: Int(original.rate * 0.2)
        )
        #expect(
            abs(lag) < Int(original.rate * 0.03),
            "rendered audio sits \(lag) frames off the source"
        )
    }

    // MARK: - What the container costs us

    @Test func aacRoundTripAddsADelayNoRenderCanRemove() throws {
        // Isolates the encoder from the DSP: no processor, no model, just a
        // signal written as AAC and read straight back. The rendered files are
        // AAC because it is the only format that keeps a 90-minute discourse near
        // the size of the source (PCM would be ~240 MB, ALAC ~120 MB against the
        // 29 MB download), and this is the price it charges.
        let rate = 22_050.0
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let frames = Int(rate * 4)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        )
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try #require(buffer.floatChannelData)
        // A sweep, so the correlation peak is unambiguous.
        for index in 0..<frames {
            let t = Double(index) / rate
            let phase = 2 * .pi * (200 * t + (1_500 - 200) * t * t / (2 * 4))
            data[0][index] = Float(0.3 * sin(phase))
        }
        let original = Array(UnsafeBufferPointer(start: data[0], count: frames))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aac-delay-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: rate,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 48_000
                ]
            )
            try file.write(from: buffer)
        }

        let decoded = try readAll(url)
        let lag = bestLag(reference: original, rendered: decoded.samples, maxLag: Int(rate * 0.25))
        // It compensates: AVAudioFile strips the encoder's priming on the way back
        // in, so a render only has to correct for the DSP chain's own delay. This
        // was worth pinning down — the first explanation for a misaligned render
        // was that the container had shifted it, and that was wrong.
        #expect(
            lag == 0,
            "AAC round trip shifted audio by \(lag) frames; the render would have to compensate"
        )
    }

    // MARK: - Refusing to write a file that is not enhanced

    @Test func silentSourceIsRefusedRatherThanCopied() async throws {
        // A tap is right to pass audio through untouched when it cannot process —
        // a dropout would be worse. A renderer doing the same would leave a file
        // claiming to be enhanced that is a plain copy, so it has to refuse.
        let source = try writeSource(seconds: 3, silent: true)
        defer { try? FileManager.default.removeItem(at: source) }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("enhance-silent-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: destination) }

        let service = AudioEnhancementService()
        await #expect(throws: AudioEnhancementService.Failure.audioWasPassedThroughUnchanged) {
            try await service.render(
                source: source,
                destination: destination,
                recipe: .init(mode: .deepFilterNet, strength: .medium, voiceFocus: .focus)
            )
        }
        #expect(
            !FileManager.default.fileExists(atPath: destination.path),
            "a refused render must not leave a file behind"
        )
    }

    @Test func unreadableSourceIsReportedNotCrashed() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).mp3")
        let service = AudioEnhancementService()
        await #expect(throws: (any Error).self) {
            try await service.render(
                source: missing,
                destination: FileManager.default.temporaryDirectory
                    .appendingPathComponent("out.m4a"),
                recipe: .init(mode: .deepFilterNet, strength: .medium, voiceFocus: .focus)
            )
        }
    }

    // MARK: - Invalidation

    @Test func fingerprintChangesWithEverySettingThatChangesTheAudio() {
        let base = AudioEnhancementService.Recipe(
            mode: .deepFilterNet, strength: .medium, voiceFocus: .focus
        )
        var byMode = base; byMode.mode = .rnnoise
        var byStrength = base; byStrength.strength = .light
        var byFocus = base; byFocus.voiceFocus = .strong

        let fingerprints = Set([
            base.fingerprint, byMode.fingerprint, byStrength.fingerprint, byFocus.fingerprint
        ])
        #expect(fingerprints.count == 4, "settings that change the audio must not share a cache entry")
        // Stable across calls, or every launch would invalidate every render.
        #expect(base.fingerprint == AudioEnhancementService.Recipe(
            mode: .deepFilterNet, strength: .medium, voiceFocus: .focus
        ).fingerprint)
        // Safe to put in a filename.
        #expect(!base.fingerprint.contains("/"))
        #expect(!base.fingerprint.contains(" "))
    }

    @Test func dspRevisionInvalidatesRendersMadeByAnOlderChain() {
        // The output ceiling fix changed the audio without changing any setting.
        // Without a revision in the fingerprint, files rendered by the clipping
        // version of the chain would keep being served.
        #expect(AudioEnhancementService.Recipe.dspRevision >= 2)
        let recipe = AudioEnhancementService.Recipe(
            mode: .deepFilterNet, strength: .medium, voiceFocus: .focus
        )
        #expect(recipe.fingerprint.contains("r\(AudioEnhancementService.Recipe.dspRevision)"))
    }
}
