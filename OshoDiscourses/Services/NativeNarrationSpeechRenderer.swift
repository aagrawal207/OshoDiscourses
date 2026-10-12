import AVFoundation
import CoreAudio
import Foundation
import os

enum NativeNarrationSpeechError: String, LocalizedError {
    case busy, emptyText, voiceUnavailable, invalidOutput, outputExists
    case noAudio, invalidBuffer, unsupportedFormat, formatChanged, incompleteAudio, timedOut
    case invalidSegment, exportUnavailable

    var errorDescription: String? {
        switch self {
        case .busy: return "Narration preparation is already running."
        case .emptyText: return "There is no text to narrate."
        case .voiceUnavailable: return "The selected system voice is no longer installed. Choose another voice."
        case .invalidOutput: return "Narration needs a writable local M4A destination."
        case .outputExists: return "A narration file already exists at this destination."
        case .noAudio: return "The system voice did not produce any audio."
        case .invalidBuffer, .unsupportedFormat, .formatChanged:
            return "The system voice produced an unsupported audio format."
        case .incompleteAudio: return "The narration audio is incomplete. Please try again."
        case .timedOut: return "Narration preparation stopped responding. Please try again."
        case .invalidSegment: return "A narration segment is missing, empty, or damaged."
        case .exportUnavailable: return "This device could not assemble the narration audio."
        }
    }
}

private let narrationSpeechLog = Logger(subsystem: "com.agraabhi.oshodiscourses", category: "NarrationSpeech")

@MainActor
final class NativeNarrationSpeechRenderer: NarrationSpeechRendering {
    private var operation: Task<TimeInterval, Error>?

    init() {}

    static func availableVoices() -> [NarrationVoice] {
        var identifiers = Set<String>()
        return AVSpeechSynthesisVoice.speechVoices()
            .filter {
                isOrdinarySystemVoice($0) && identifiers.insert($0.identifier).inserted
                    && AVSpeechSynthesisVoice(identifier: $0.identifier) != nil
            }
            .map { NarrationVoice(id: $0.identifier, name: $0.name, language: $0.language, quality: $0.quality.rawValue) }
            .sorted {
                if $0.quality != $1.quality { return $0.quality > $1.quality }
                if $0.language != $1.language { return $0.language < $1.language }
                if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                return $0.id < $1.id
            }
    }

    func render(text: String, voiceID: String, to outputURL: URL) async throws -> TimeInterval {
        try await perform(stage: "render", to: outputURL) { temporaryURL in
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NativeNarrationSpeechError.emptyText
            }
            guard let voice = AVSpeechSynthesisVoice(identifier: voiceID),
                  voice.identifier == voiceID,
                  Self.isOrdinarySystemVoice(voice),
                  AVSpeechSynthesisVoice.speechVoices().contains(where: { $0.identifier == voiceID }) else {
                throw NativeNarrationSpeechError.voiceUnavailable
            }
            let sink = NarrationSpeechBufferSink(outputURL: temporaryURL)
            let session = NativeNarrationSynthesisSession(text: text, voice: voice, sink: sink)
            defer { session.stop() }
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    sink.start(continuation)
                    session.start()
                }
            } onCancel: {
                sink.cancel()
                Task { @MainActor in session.stop() }
            }
        }
    }

    func assemble(segments: [URL], to outputURL: URL) async throws -> TimeInterval {
        try await perform(stage: "assemble", to: outputURL) { temporaryURL in
            try await NativeNarrationAssembler().assemble(segments: segments, to: temporaryURL)
        }
    }

    func cancel() {
        operation?.cancel()
    }

    private static func isOrdinarySystemVoice(_ voice: AVSpeechSynthesisVoice) -> Bool {
        voice.identifier.hasPrefix("com.apple.")
            && !voice.voiceTraits.contains(.isPersonalVoice)
            && !voice.voiceTraits.contains(.isNoveltyVoice)
    }

    private func perform(
        stage: String, to outputURL: URL,
        work: @escaping @MainActor (URL) async throws -> TimeInterval
    ) async throws -> TimeInterval {
        guard operation == nil else {
            narrationSpeechLog.info("Stage=\(stage, privacy: .public) outcome=busy")
            throw NativeNarrationSpeechError.busy
        }
        try Task.checkCancellation()
        // A generation only writes its own scratch file, including callbacks arriving after cancellation.
        let temporaryURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".narration-\(UUID().uuidString).m4a")
        let task = Task {
            try Task.checkCancellation()
            try NarrationAudioFiles.validateDestination(outputURL)
            return try await work(temporaryURL)
        }
        operation = task
        defer { operation = nil }
        var published = false
        narrationSpeechLog.info("Stage=\(stage, privacy: .public) outcome=started")
        do {
            let duration = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard !task.isCancelled else { throw CancellationError() }
            guard duration.isFinite, duration > 0 else { throw NativeNarrationSpeechError.noAudio }
            try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
            published = true
            try Task.checkCancellation()
            narrationSpeechLog.info("Stage=\(stage, privacy: .public) outcome=succeeded")
            return duration
        } catch {
            NarrationAudioFiles.removePartial(temporaryURL)
            if published { NarrationAudioFiles.removePartial(outputURL) }
            let failure: Error = Task.isCancelled || task.isCancelled ? CancellationError() : error
            let outcome = (failure as? NativeNarrationSpeechError)?.rawValue
                ?? (failure is CancellationError ? "cancelled" : "systemFailure")
            narrationSpeechLog.error("Stage=\(stage, privacy: .public) outcome=\(outcome, privacy: .public)")
            throw failure
        }
    }
}

@MainActor
private final class NativeNarrationSynthesisSession {
    private let synthesizer = AVSpeechSynthesizer()
    private let utterance: AVSpeechUtterance
    private let delegate: NativeNarrationSpeechDelegate
    private let sink: NarrationSpeechBufferSink

    init(text: String, voice: AVSpeechSynthesisVoice, sink: NarrationSpeechBufferSink) {
        self.sink = sink
        delegate = NativeNarrationSpeechDelegate(sink: sink)
        utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.prefersAssistiveTechnologySettings = false
        synthesizer.delegate = delegate
        #if os(iOS)
        synthesizer.usesApplicationAudioSession = false
        #endif
    }

    func start() {
        synthesizer.write(utterance, toBufferCallback: sink.bufferCallback())
    }

    func stop() {
        synthesizer.delegate = nil
        synthesizer.stopSpeaking(at: .immediate)
    }
}

private final class NativeNarrationSpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    let sink: NarrationSpeechBufferSink

    init(sink: NarrationSpeechBufferSink) { self.sink = sink }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        sink.speechDidFinish()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        sink.cancel()
    }
}

// File/converter state is queue-confined; the lock protects only admission and terminal failure.
// Each callback copies PCM before returning, with at most four 8192-frame copies in flight.
final class NarrationSpeechBufferSink: @unchecked Sendable {
    private struct Control {
        var accepting = true
        var terminal = false
        var failure: Error?
    }

    private let control = OSAllocatedUnfairLock(initialState: Control())
    private let callbackLock = NSLock()
    private let slots = DispatchSemaphore(value: 4)
    private let queue = DispatchQueue(label: "com.agraabhi.oshodiscourses.narration-writer", qos: .utility)
    private let outputURL: URL
    private let inactivityTimeout: TimeInterval
    private let finishTimeout: TimeInterval
    private let totalTimeout: TimeInterval
    private var writer: NativeNarrationPCMWriter?
    private var ownsOutput = false
    private var continuation: CheckedContinuation<TimeInterval, Error>?
    private var result: Result<TimeInterval, Error>?
    private var timer: DispatchSourceTimer?
    private var startedAt = ProcessInfo.processInfo.systemUptime
    private var lastBufferAt = ProcessInfo.processInfo.systemUptime
    private var speechFinishedAt: TimeInterval?

    init(
        outputURL: URL, inactivityTimeout: TimeInterval = 30,
        finishTimeout: TimeInterval = 5, totalTimeout: TimeInterval = 600
    ) {
        self.outputURL = outputURL
        self.inactivityTimeout = inactivityTimeout
        self.finishTimeout = finishTimeout
        self.totalTimeout = totalTimeout
    }

    func start(_ continuation: CheckedContinuation<TimeInterval, Error>) {
        queue.async { [self] in
            if let result = self.result {
                continuation.resume(with: result)
                return
            }
            guard self.continuation == nil else {
                continuation.resume(throwing: NativeNarrationSpeechError.busy)
                return
            }
            self.continuation = continuation
            self.startedAt = ProcessInfo.processInfo.systemUptime
            self.lastBufferAt = self.startedAt
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            let interval = max(0.01, min(1, self.inactivityTimeout / 2, self.finishTimeout / 2, self.totalTimeout / 2))
            timer.schedule(deadline: .now() + interval, repeating: interval)
            timer.setEventHandler { [weak self] in self?.checkTimeout() }
            self.timer = timer
            timer.resume()
        }
    }

    func value() async throws -> TimeInterval {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { start($0) }
        } onCancel: {
            cancel()
        }
    }

    // This factory is nonisolated so an AVFoundation callback never inherits MainActor isolation.
    func bufferCallback() -> AVSpeechSynthesizer.BufferCallback {
        { [self] buffer in receive(buffer) }
    }

    func receive(_ buffer: AVAudioBuffer) {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        guard control.withLock({ $0.accepting }) else { return }
        guard let pcm = buffer as? AVAudioPCMBuffer else {
            fail(NativeNarrationSpeechError.invalidBuffer)
            return
        }
        if pcm.frameLength == 0 {
            let accepted = control.withLock {
                guard $0.accepting else { return false }
                $0.accepting = false
                return true
            }
            if accepted { queue.async { self.finishAudio() } }
            return
        }
        do {
            try OwnedNarrationPCM.validate(pcm)
            var offset: AVAudioFrameCount = 0
            while offset < pcm.frameLength {
                while slots.wait(timeout: .now() + 0.05) == .timedOut {
                    guard control.withLock({ $0.accepting }) else { return }
                }
                guard control.withLock({ $0.accepting }) else {
                    slots.signal()
                    return
                }
                let count = min(8192, pcm.frameLength - offset)
                let copy: OwnedNarrationPCM
                do {
                    copy = try OwnedNarrationPCM(copying: pcm, offset: offset, count: count)
                } catch {
                    slots.signal()
                    throw error
                }
                queue.async {
                    defer { self.slots.signal() }
                    self.append(copy)
                }
                offset += count
            }
        } catch {
            fail(error)
        }
    }

    func speechDidFinish() {
        // Delegate completion may precede the final buffer. Only the empty-buffer marker seals audio.
        queue.async {
            if self.speechFinishedAt == nil { self.speechFinishedAt = ProcessInfo.processInfo.systemUptime }
        }
    }

    func cancel() { fail(CancellationError()) }

    private func fail(_ error: Error) {
        let accepted = control.withLock {
            guard !$0.terminal, $0.failure == nil else { return false }
            $0.accepting = false
            $0.failure = error
            return true
        }
        if accepted { queue.async { self.complete(.failure(error)) } }
    }

    private func checkFailure() throws {
        if let error = control.withLock({ $0.failure }) { throw error }
    }

    private func append(_ pcm: OwnedNarrationPCM) {
        guard result == nil else { return }
        do {
            try checkFailure()
            if writer == nil {
                try NarrationAudioFiles.validateDestination(outputURL)
                ownsOutput = true
                writer = try NativeNarrationPCMWriter(outputURL: outputURL, format: pcm.buffer.format)
            }
            try writer?.append(pcm.buffer)
            lastBufferAt = ProcessInfo.processInfo.systemUptime
        } catch {
            complete(.failure(error))
        }
    }

    private func finishAudio() {
        guard result == nil else { return }
        do {
            try checkFailure()
            guard let writer else { throw NativeNarrationSpeechError.noAudio }
            let expected = writer.duration
            let frameCount = writer.frameCount
            writer.close()
            self.writer = nil
            let measured = try NarrationAudioFiles.inspect(
                outputURL, expectedDuration: expected, expectedFrameCount: frameCount,
                requireSignal: true, checkCancellation: checkFailure
            )
            complete(.success(measured))
        } catch {
            complete(.failure(error))
        }
    }

    private func checkTimeout() {
        guard result == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - startedAt >= totalTimeout || now - lastBufferAt >= inactivityTimeout {
            complete(.failure(NativeNarrationSpeechError.timedOut))
        } else if let speechFinishedAt, now - speechFinishedAt >= finishTimeout {
            complete(.failure(writer == nil ? NativeNarrationSpeechError.noAudio : .incompleteAudio))
        }
    }

    private func complete(_ proposed: Result<TimeInterval, Error>) {
        guard result == nil else { return }
        let resolved = control.withLock {
            $0.accepting = false
            $0.terminal = true
            return $0.failure.map { Result<TimeInterval, Error>.failure($0) } ?? proposed
        }
        timer?.cancel()
        timer = nil
        writer?.close()
        writer = nil
        if case .failure = resolved, ownsOutput { NarrationAudioFiles.removePartial(outputURL) }
        result = resolved
        continuation?.resume(with: resolved)
        continuation = nil
    }
}

// The copy has one consumer, the sink's serial queue; AVFoundation retains ownership of the original.
private struct OwnedNarrationPCM: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    static func validate(_ source: AVAudioPCMBuffer) throws {
        let format = source.format
        guard format.commonFormat != .otherFormat,
              format.sampleRate.isFinite, (8_000...192_000).contains(format.sampleRate),
              (1...2).contains(format.channelCount), source.frameLength <= source.frameCapacity else {
            throw NativeNarrationSpeechError.unsupportedFormat
        }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
        guard bytesPerFrame > 0,
              buffers.count == (format.isInterleaved ? 1 : Int(format.channelCount)),
              buffers.allSatisfy({
                  $0.mData != nil && UInt64($0.mDataByteSize) >= UInt64(source.frameLength) * UInt64(bytesPerFrame)
                      && $0.mNumberChannels == (format.isInterleaved ? format.channelCount : 1)
              }) else { throw NativeNarrationSpeechError.invalidBuffer }
    }

    init(copying source: AVAudioPCMBuffer, offset: AVAudioFrameCount, count: AVAudioFrameCount) throws {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: count) else {
            throw NativeNarrationSpeechError.invalidBuffer
        }
        copy.frameLength = count
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        let stride = Int(source.format.streamDescription.pointee.mBytesPerFrame)
        for index in sourceBuffers.indices {
            guard let input = sourceBuffers[index].mData, let output = destination[index].mData else {
                throw NativeNarrationSpeechError.invalidBuffer
            }
            memcpy(output, input.advanced(by: Int(offset) * stride), Int(count) * stride)
        }
        buffer = copy
    }
}

private final class NativeNarrationPCMWriter {
    private let sourceFormat: AVAudioFormat
    private let file: AVAudioFile
    private let converter: AVAudioConverter?
    private let converted: AVAudioPCMBuffer
    private(set) var frameCount: AVAudioFramePosition = 0

    var duration: TimeInterval { Double(frameCount) / sourceFormat.sampleRate }

    init(outputURL: URL, format: AVAudioFormat) throws {
        sourceFormat = format
        let rate = format.sampleRate
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue,
        ]
        // AAC's bitrate ceiling varies with sample rate and channel count, including 16/22.05 kHz voices.
        guard let encodedFormat = AVAudioFormat(settings: settings),
              let encoder = AVAudioConverter(from: format, to: encodedFormat),
              let bitRate = encoder.applicableEncodeBitRates?.map(\.intValue)
                .filter({ $0 > 0 && $0 <= 128_000 * Int(format.channelCount) }).max() else {
            throw NativeNarrationSpeechError.unsupportedFormat
        }
        settings[AVEncoderBitRateKey] = bitRate
        file = try AVAudioFile(forWriting: outputURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.sampleRate == rate, file.processingFormat.channelCount == format.channelCount,
              let converted = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else {
            file.close()
            throw NativeNarrationSpeechError.unsupportedFormat
        }
        self.converted = converted
        if format.isEqual(file.processingFormat) {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: format, to: file.processingFormat) else {
                file.close()
                throw NativeNarrationSpeechError.unsupportedFormat
            }
            self.converter = converter
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        guard sourceFormat.isEqual(buffer.format) else { throw NativeNarrationSpeechError.formatChanged }
        let normalized: AVAudioPCMBuffer
        if let converter {
            converted.frameLength = 0
            try converter.convert(to: converted, from: buffer)
            guard converted.frameLength == buffer.frameLength else { throw NativeNarrationSpeechError.incompleteAudio }
            normalized = converted
        } else {
            normalized = buffer
        }
        guard let channels = normalized.floatChannelData else { throw NativeNarrationSpeechError.invalidBuffer }
        for channel in 0..<Int(normalized.format.channelCount) {
            for frame in 0..<Int(normalized.frameLength) where !channels[channel][frame].isFinite {
                throw NativeNarrationSpeechError.invalidBuffer
            }
        }
        try file.write(from: normalized)
        frameCount += AVAudioFramePosition(normalized.frameLength)
    }

    func close() { file.close() }
}

private enum NarrationAudioFiles {
    static func validateDestination(_ url: URL) throws {
        guard url.isFileURL, url.pathExtension.lowercased() == "m4a",
              (try? url.deletingLastPathComponent().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw NativeNarrationSpeechError.invalidOutput
        }
        guard !FileManager.default.fileExists(atPath: url.path) else { throw NativeNarrationSpeechError.outputExists }
    }

    static func removePartial(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do { try FileManager.default.removeItem(at: url) }
        catch { narrationSpeechLog.error("Stage=cleanup outcome=systemFailure") }
    }

    static func inspect(
        _ url: URL, expectedDuration: TimeInterval? = nil, expectedFrameCount: AVAudioFramePosition? = nil,
        requireSignal: Bool = false,
        checkCancellation: () throws -> Void
    ) throws -> TimeInterval {
        try checkCancellation()
        guard url.isFileURL,
              (try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])).isRegularFile == true else {
            throw NativeNarrationSpeechError.invalidSegment
        }
        let file = try AVAudioFile(forReading: url)
        defer { file.close() }
        let format = file.processingFormat
        let length = file.length
        guard file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC,
              length > 0, format.sampleRate.isFinite, format.sampleRate > 0,
              (1...2).contains(format.channelCount),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192),
              let channels = buffer.floatChannelData else { throw NativeNarrationSpeechError.invalidSegment }
        var decoded: AVAudioFramePosition = 0
        var hasSignal = false
        while decoded < length {
            try checkCancellation()
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, length - decoded)))
            guard buffer.frameLength > 0 else { throw NativeNarrationSpeechError.incompleteAudio }
            decoded += AVAudioFramePosition(buffer.frameLength)
            guard decoded <= length else { throw NativeNarrationSpeechError.incompleteAudio }
            for channel in 0..<Int(format.channelCount) {
                for frame in 0..<Int(buffer.frameLength) {
                    let sample = channels[channel][frame]
                    guard sample.isFinite else { throw NativeNarrationSpeechError.invalidBuffer }
                    hasSignal = hasSignal || sample != 0
                }
            }
        }
        guard decoded == length, decoded > 0 else { throw NativeNarrationSpeechError.incompleteAudio }
        if let expectedFrameCount, decoded != expectedFrameCount { throw NativeNarrationSpeechError.incompleteAudio }
        if requireSignal, !hasSignal { throw NativeNarrationSpeechError.noAudio }
        let duration = Double(decoded) / format.sampleRate
        if let expectedDuration, abs(duration - expectedDuration) > 0.05 {
            throw NativeNarrationSpeechError.incompleteAudio
        }
        return duration
    }
}

private actor NativeNarrationAssembler {
    func assemble(segments: [URL], to outputURL: URL) async throws -> TimeInterval {
        guard !segments.isEmpty else { throw NativeNarrationSpeechError.invalidSegment }
        let composition = AVMutableComposition()
        guard let destination = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NativeNarrationSpeechError.exportUnavailable
        }
        var cursor = CMTime.zero
        var batchDuration = CMTime.zero
        var tracks: [AVAssetTrack] = []
        var ranges: [NSValue] = []
        var assets: [AVURLAsset] = []
        for (index, url) in segments.enumerated() {
            try Task.checkCancellation()
            let measured = try NarrationAudioFiles.inspect(url, checkCancellation: Task.checkCancellation)
            let asset = AVURLAsset(url: url)
            let (source, range) = try await withTaskCancellationHandler {
                let sourceTracks = try await asset.loadTracks(withMediaType: .audio)
                guard sourceTracks.count == 1, let source = sourceTracks.first,
                      try await asset.load(.isPlayable) else { throw NativeNarrationSpeechError.invalidSegment }
                let (range, _) = try await source.load(.timeRange, .formatDescriptions)
                return (source, range)
            } onCancel: {
                asset.cancelLoading()
            }
            guard range.isValid, range.start.isNumeric, range.duration.isNumeric, range.duration.seconds > 0,
                  abs(range.duration.seconds - measured) <= 0.05 else {
                throw NativeNarrationSpeechError.invalidSegment
            }
            tracks.append(source)
            ranges.append(NSValue(timeRange: range))
            assets.append(asset)
            batchDuration = CMTimeAdd(batchDuration, range.duration)
            // Batched insertion avoids rebuilding a thousand-edit timeline once per paragraph.
            if tracks.count == 64 || index == segments.count - 1 {
                try Task.checkCancellation()
                // AVAssetTrack.asset is weak; source assets must survive until insertion copies the edits.
                try withExtendedLifetime(assets) {
                    try destination.insertTimeRanges(ranges, of: tracks, at: cursor)
                }
                cursor = CMTimeAdd(cursor, batchDuration)
                batchDuration = .zero
                tracks.removeAll(keepingCapacity: true)
                ranges.removeAll(keepingCapacity: true)
                assets.removeAll(keepingCapacity: true)
            }
        }
        guard cursor.isNumeric, cursor.seconds.isFinite, cursor.seconds > 0,
              let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A),
              exporter.supportedFileTypes.contains(.m4a) else { throw NativeNarrationSpeechError.exportUnavailable }
        try Task.checkCancellation()
        let expectedDuration = cursor.seconds
        let exportTimeout = max(120, expectedDuration * 2)
        let export = Task { [self] in try await exporter.export(to: outputURL, as: .m4a, isolation: self) }
        let deadline = Task {
            try await Task.sleep(for: .seconds(exportTimeout))
            export.cancel()
        }
        defer { deadline.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await export.value
            } onCancel: {
                export.cancel()
            }
        } catch {
            if !Task.isCancelled, export.isCancelled { throw NativeNarrationSpeechError.timedOut }
            throw error
        }
        try Task.checkCancellation()
        return try NarrationAudioFiles.inspect(
            outputURL, expectedDuration: expectedDuration, checkCancellation: Task.checkCancellation
        )
    }
}
