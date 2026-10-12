import Accelerate
import AVFoundation
import Foundation

/// Writes a copy of a rendered passage whose pauses are lengthened toward `targetDuration`.
protocol NarrationPacing: Sendable {
    /// `output` is a new .m4a path that does not exist yet. Returns the output's decoded duration in seconds.
    /// If `targetDuration` is not meaningfully longer than the input (<= input + 0.2 s) or not finite,
    /// writes an unchanged copy of the input.
    func pace(_ input: URL, to output: URL, targetDuration: TimeInterval) async throws -> TimeInterval
}

struct NarrationPauseInsertion: Equatable, Sendable {
    /// Input frame before which the silence is inserted.
    let position: Int
    let frames: Int
}

enum NarrationPausePlan {
    static let minimumPause: TimeInterval = 0.12
    static let interiorCap: TimeInterval = 3
    static let trailingCap: TimeInterval = 6

    /// Plans where silence goes, never adding more than `framesToAdd` in total.
    /// A run starting at frame 0 is leading silence; a run reaching `totalFrames` is the trailing pause.
    static func insertions(
        silentRuns: [Range<Int>], totalFrames: Int, framesToAdd: Int, sampleRate: Double
    ) -> [NarrationPauseInsertion] {
        guard totalFrames > 0, framesToAdd > 0, sampleRate.isFinite, sampleRate > 0 else { return [] }
        let minimumFrames = minimumPause * sampleRate
        var interior: [Range<Int>] = []
        var trailing = totalFrames..<totalFrames
        for run in silentRuns {
            let run = run.clamped(to: 0..<totalFrames)
            guard !run.isEmpty, run.lowerBound > 0 else { continue }
            if run.upperBound == totalFrames {
                trailing = run
            } else if Double(run.count) >= minimumFrames {
                interior.append(run)
            }
        }
        let longestInterior = Double(interior.map(\.count).max() ?? 0)
        var positions = interior.map { $0.lowerBound + $0.count / 2 }
        var weights = interior.map { Double($0.count) }
        var caps = interior.map { _ in (interiorCap * sampleRate).rounded(.down) }
        // The trailing pause is a paragraph break, so it weighs at least as much as any sentence pause,
        // and still receives time when the voice stopped without any trailing silence.
        positions.append(totalFrames)
        weights.append(max(Double(trailing.count), longestInterior, minimumFrames))
        caps.append((trailingCap * sampleRate).rounded(.down))

        let frames = allocate(Double(framesToAdd), weights: weights, caps: caps)
        return zip(positions, frames)
            .filter { $0.1 > 0 }
            .map { NarrationPauseInsertion(position: $0.0, frames: $0.1) }
            .sorted { $0.position < $1.position }
    }

    /// Weighted water-filling: shares are proportional to weight until a share reaches its cap.
    private static func allocate(_ total: Double, weights: [Double], caps: [Double]) -> [Int] {
        var shares = [Double](repeating: 0, count: weights.count)
        var remaining = total
        var openWeight = weights.reduce(0, +)
        // Visiting in rising cap/weight order means the first uncapped share leaves every later one uncapped.
        let order = weights.indices.sorted { caps[$0] * weights[$1] < caps[$1] * weights[$0] }
        for (step, index) in order.enumerated() {
            guard remaining > 0, openWeight > 0 else { break }
            let fair = remaining * weights[index] / openWeight
            if fair >= caps[index] {
                shares[index] = caps[index]
                remaining -= caps[index]
                openWeight -= weights[index]
            } else {
                for open in order[step...] { shares[open] = remaining * weights[open] / openWeight }
                break
            }
        }
        var frames = shares.map { Int($0.rounded(.down)) }
        let budget = Int(min(total, caps.reduce(0, +)).rounded(.down))
        var leftover = budget - frames.reduce(0, +)
        let byFraction = shares.indices.sorted {
            shares[$0] - shares[$0].rounded(.down) > shares[$1] - shares[$1].rounded(.down)
        }
        for index in byFraction where leftover > 0 && Double(frames[index]) < caps[index] {
            frames[index] += 1
            leftover -= 1
        }
        return frames
    }
}

enum NarrationSilenceDetector {
    static let window: TimeInterval = 0.01
    /// About -34 dB below loud speech: quiet fricatives stay speech, codec residue in pauses does not.
    static let relativeThreshold: Float = 0.02
    /// About -66 dBFS, so AAC noise in a pause is never mistaken for a very quiet voice.
    static let absoluteFloor: Float = 0.0005

    /// Returns maximal runs of 10 ms windows whose RMS, across all channels, is below the silence threshold.
    static func silentRuns(in channels: [[Float]], sampleRate: Double) throws -> [Range<Int>] {
        guard let frameCount = channels.first?.count, frameCount > 0, sampleRate.isFinite, sampleRate > 0 else {
            return []
        }
        let windowFrames = max(1, Int((window * sampleRate).rounded()))
        var levels: [Float] = []
        levels.reserveCapacity(frameCount / windowFrames + 1)
        var start = 0
        while start < frameCount {
            if levels.count % 1_000 == 0 { try Task.checkCancellation() }
            let count = min(windowFrames, frameCount - start)
            var energy: Float = 0
            for channel in channels {
                var meanSquare: Float = 0
                channel.withUnsafeBufferPointer {
                    vDSP_measqv($0.baseAddress! + start, 1, &meanSquare, vDSP_Length(count))
                }
                energy += meanSquare
            }
            levels.append((energy / Float(channels.count)).squareRoot())
            start += count
        }
        let threshold = max(absoluteFloor, relativeThreshold * loudLevel(levels))
        var runs: [Range<Int>] = []
        var runStart: Int?
        for (index, level) in levels.enumerated() {
            let frame = index * windowFrames
            if level < threshold {
                if runStart == nil { runStart = frame }
            } else if let open = runStart {
                runs.append(open..<frame)
                runStart = nil
            }
        }
        if let open = runStart { runs.append(open..<frameCount) }
        return runs
    }

    /// The 95th percentile of audible windows ignores isolated peaks yet tracks a quiet voice.
    private static func loudLevel(_ levels: [Float]) -> Float {
        let audible = levels.filter { $0 >= absoluteFloor }.sorted()
        guard !audible.isEmpty else { return 0 }
        return audible[min(audible.count - 1, Int(Double(audible.count) * 0.95))]
    }
}

struct NarrationPausePacer: NarrationPacing {
    private static let chunkFrames = 8192
    private let chunkWritten: (@Sendable () -> Void)?

    init() { chunkWritten = nil }

    /// `chunkWritten` runs on the pacing task after each encoded chunk.
    init(chunkWritten: @escaping @Sendable () -> Void) { self.chunkWritten = chunkWritten }

    func pace(_ input: URL, to output: URL, targetDuration: TimeInterval) async throws -> TimeInterval {
        try Task.checkCancellation()
        try NarrationAudioFiles.validateDestination(output)
        let temporaryURL = output.deletingLastPathComponent()
            .appendingPathComponent(".narration-pacing-\(UUID().uuidString).m4a")
        do {
            let duration = try write(input, to: temporaryURL, targetDuration: targetDuration)
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: temporaryURL, to: output)
            return duration
        } catch {
            NarrationAudioFiles.removePartial(temporaryURL)
            throw Task.isCancelled ? CancellationError() : error
        }
    }

    private func write(_ input: URL, to temporaryURL: URL, targetDuration: TimeInterval) throws -> TimeInterval {
        let source = try AVAudioFile(forReading: input)
        let format = source.processingFormat
        let rate = format.sampleRate
        let inputFrames = Int(source.length)
        guard source.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC,
              rate.isFinite, rate > 0, (1...2).contains(format.channelCount), inputFrames > 0 else {
            source.close()
            throw NativeNarrationSpeechError.invalidSegment
        }
        guard targetDuration.isFinite, targetDuration > Double(inputFrames) / rate + 0.2 else {
            source.close()
            try FileManager.default.copyItem(at: input, to: temporaryURL)
            return try NarrationAudioFiles.inspect(
                temporaryURL, requireSignal: true, checkCancellation: Task.checkCancellation
            )
        }
        let channels: [[Float]]
        do {
            defer { source.close() }
            channels = try read(source, frames: inputFrames)
        }
        // Clamped in floating point so an absurd target cannot overflow; the planner's caps bound it anyway.
        let extra = min((targetDuration * rate).rounded(.down) - Double(inputFrames), Double(Int32.max))
        let runs = try NarrationSilenceDetector.silentRuns(in: channels, sampleRate: rate)
        let plan = NarrationPausePlan.insertions(
            silentRuns: runs, totalFrames: inputFrames, framesToAdd: Int(extra), sampleRate: rate
        )
        let written = try encode(channels, format: format, plan: plan, to: temporaryURL)
        return try NarrationAudioFiles.inspect(
            temporaryURL, expectedFrameCount: AVAudioFramePosition(written),
            requireSignal: true, checkCancellation: Task.checkCancellation
        )
    }

    private func read(_ file: AVAudioFile, frames: Int) throws -> [[Float]] {
        let channelCount = Int(file.processingFormat.channelCount)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(Self.chunkFrames)),
              let data = buffer.floatChannelData else { throw NativeNarrationSpeechError.invalidSegment }
        var channels = [[Float]](repeating: [], count: channelCount)
        for index in channels.indices { channels[index].reserveCapacity(frames) }
        while channels[0].count < frames {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Self.chunkFrames, frames - channels[0].count)))
            let count = Int(buffer.frameLength)
            guard count > 0 else { throw NativeNarrationSpeechError.incompleteAudio }
            for index in channels.indices {
                let samples = UnsafeBufferPointer(start: data[index], count: count)
                guard samples.allSatisfy(\.isFinite) else { throw NativeNarrationSpeechError.invalidBuffer }
                channels[index].append(contentsOf: samples)
            }
        }
        guard channels[0].count == frames else { throw NativeNarrationSpeechError.incompleteAudio }
        return channels
    }

    private func encode(
        _ channels: [[Float]], format: AVAudioFormat, plan: [NarrationPauseInsertion], to url: URL
    ) throws -> Int {
        let writer = try NativeNarrationPCMWriter(outputURL: url, format: format)
        defer { writer.close() }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.chunkFrames)),
              let data = buffer.floatChannelData else { throw NativeNarrationSpeechError.invalidBuffer }

        func emit(_ frames: Int, from start: Int?) throws {
            var offset = 0
            while offset < frames {
                try Task.checkCancellation()
                let count = min(Self.chunkFrames, frames - offset)
                for index in channels.indices {
                    if let start {
                        channels[index].withUnsafeBufferPointer {
                            data[index].update(from: $0.baseAddress! + start + offset, count: count)
                        }
                    } else {
                        data[index].update(repeating: 0, count: count)
                    }
                }
                buffer.frameLength = AVAudioFrameCount(count)
                try writer.append(buffer)
                chunkWritten?()
                offset += count
            }
        }

        let total = channels[0].count
        var cursor = 0
        for insertion in plan {
            try emit(insertion.position - cursor, from: cursor)
            try emit(insertion.frames, from: nil)
            cursor = insertion.position
        }
        try emit(total - cursor, from: cursor)
        return Int(writer.frameCount)
    }
}
