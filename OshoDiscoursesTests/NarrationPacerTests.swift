import AVFoundation
import Foundation
import os
import Testing
@testable import OshoDiscourses

@Suite(.serialized)
struct NarrationPausePacerTests {
    private static let standard: [PacerFixture.Piece] = [
        .silence(0.3), .tone(1.0), .silence(0.4), .tone(1.0), .silence(0.15), .tone(0.5), .silence(0.2),
    ]

    @Test func outputReachesTargetAsDecodableAAC() async throws {
        let directory = try PacerFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.m4a")
        let inputDuration = try PacerFixture.write(Self.standard, to: input)
        let output = directory.appendingPathComponent("paced.m4a")
        let target = inputDuration + 2.0

        let duration = try await NarrationPausePacer().pace(input, to: output, targetDuration: target)

        #expect(abs(duration - target) < 0.1)
        #expect(duration <= target)
        let file = try AVAudioFile(forReading: output)
        defer { file.close() }
        #expect(file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
        #expect(file.processingFormat.sampleRate == 22_050)
        #expect(file.processingFormat.channelCount == 1)
        #expect(abs(Double(file.length) / 22_050 - duration) < 1 / 22_050.0)
        let measured = try NarrationAudioFiles.inspect(output, requireSignal: true, checkCancellation: {})
        #expect(measured == duration)
        #expect(PacerFixture.temporaryFiles(in: directory).isEmpty)
    }

    @Test func leadingSilenceAndSpeechArePreserved() async throws {
        let directory = try PacerFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.m4a")
        let inputDuration = try PacerFixture.write(Self.standard, to: input)
        let output = directory.appendingPathComponent("paced.m4a")
        _ = try await NarrationPausePacer().pace(input, to: output, targetDuration: inputDuration + 3)

        let before = try PacerFixture.runs(input)
        let after = try PacerFixture.runs(output)
        #expect(before.speech.count == 3)
        #expect(after.speech.count == 3)
        #expect(abs(after.leading - before.leading) < 0.02)
        #expect(abs(after.speech.reduce(0, +) - before.speech.reduce(0, +)) < 0.05)
        for (paced, original) in zip(after.speech, before.speech) { #expect(abs(paced - original) < 0.03) }
    }

    @Test func longerPausesReceiveMoreTime() async throws {
        let directory = try PacerFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.m4a")
        let inputDuration = try PacerFixture.write(Self.standard, to: input)
        let output = directory.appendingPathComponent("paced.m4a")
        _ = try await NarrationPausePacer().pace(input, to: output, targetDuration: inputDuration + 2)

        let before = try PacerFixture.runs(input)
        let after = try PacerFixture.runs(output)
        try #require(before.gaps.count == 2 && after.gaps.count == 2)
        let longAdded = after.gaps[0] - before.gaps[0]
        let shortAdded = after.gaps[1] - before.gaps[1]
        let trailingAdded = after.trailing - before.trailing
        #expect(shortAdded > 0.1)
        #expect(longAdded > shortAdded * 2)
        #expect(trailingAdded > shortAdded * 2)
        #expect(abs(longAdded + shortAdded + trailingAdded - 2) < 0.1)
    }

    @Test func capsLimitAHugeTarget() async throws {
        let directory = try PacerFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.m4a")
        let inputDuration = try PacerFixture.write(Self.standard, to: input)
        let output = directory.appendingPathComponent("paced.m4a")

        let duration = try await NarrationPausePacer().pace(input, to: output, targetDuration: inputDuration + 100)

        let caps = 2 * NarrationPausePlan.interiorCap + NarrationPausePlan.trailingCap
        #expect(abs(duration - (inputDuration + caps)) < 0.01)
        let before = try PacerFixture.runs(input)
        let after = try PacerFixture.runs(output)
        try #require(after.gaps.count == 2)
        #expect(abs(after.gaps[0] - before.gaps[0] - NarrationPausePlan.interiorCap) < 0.05)
        #expect(abs(after.gaps[1] - before.gaps[1] - NarrationPausePlan.interiorCap) < 0.05)
        #expect(abs(after.trailing - before.trailing - NarrationPausePlan.trailingCap) < 0.05)
    }

    @Test(arguments: [0.1, 0.2, -10, -.infinity, .infinity, .nan])
    func targetNotMeaningfullyLongerCopiesInput(offset: Double) async throws {
        let directory = try PacerFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.m4a")
        let inputDuration = try PacerFixture.write(Self.standard, to: input)
        let output = directory.appendingPathComponent("paced.m4a")

        let duration = try await NarrationPausePacer().pace(input, to: output, targetDuration: inputDuration + offset)

        #expect(abs(duration - inputDuration) < 1 / 22_050.0)
        #expect(try Data(contentsOf: output) == Data(contentsOf: input))
    }

    @Test func passageEndingInSpeechGainsTrailingSilence() async throws {
        let directory = try PacerFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.m4a")
        let inputDuration = try PacerFixture.write([.silence(0.3), .tone(1.0), .silence(0.4), .tone(1.0)], to: input)
        let output = directory.appendingPathComponent("paced.m4a")

        let duration = try await NarrationPausePacer().pace(input, to: output, targetDuration: inputDuration + 1)

        #expect(abs(duration - (inputDuration + 1)) < 0.01)
        let before = try PacerFixture.runs(input)
        let after = try PacerFixture.runs(output)
        #expect(before.trailing < 0.03)
        #expect(after.trailing > 0.4)
        #expect(after.speech.count == 2)
        #expect(abs((after.speech.last ?? 0) - (before.speech.last ?? 0)) < 0.03)
    }

    @Test func stereoInputKeepsChannelsAndRate() async throws {
        let directory = try PacerFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.m4a")
        let inputDuration = try PacerFixture.write(Self.standard, to: input, rate: 44_100, channels: 2)
        let output = directory.appendingPathComponent("paced.m4a")

        let duration = try await NarrationPausePacer().pace(input, to: output, targetDuration: inputDuration + 2)

        #expect(abs(duration - (inputDuration + 2)) < 0.01)
        let file = try AVAudioFile(forReading: output)
        defer { file.close() }
        #expect(file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
        #expect(file.processingFormat.sampleRate == 44_100)
        #expect(file.processingFormat.channelCount == 2)
        let after = try PacerFixture.runs(output)
        #expect(after.speech.count == 3)
        #expect(abs(after.leading - 0.3) < 0.03)
        for channel in 0..<2 {
            #expect(try PacerFixture.runs(output, channel: channel).speech.count == 3)
        }
    }

    @Test func existingOutputIsRejectedAndLeftAlone() async throws {
        let directory = try PacerFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.m4a")
        let inputDuration = try PacerFixture.write(Self.standard, to: input)
        let output = directory.appendingPathComponent("paced.m4a")
        let existing = Data("keep".utf8)
        try existing.write(to: output)

        await #expect(throws: NativeNarrationSpeechError.outputExists) {
            try await NarrationPausePacer().pace(input, to: output, targetDuration: inputDuration + 2)
        }
        #expect(try Data(contentsOf: output) == existing)
        #expect(PacerFixture.temporaryFiles(in: directory).isEmpty)
    }

    @Test func cancellationDuringWritingLeavesNoFile() async throws {
        let directory = try PacerFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.m4a")
        let inputDuration = try PacerFixture.write(Self.standard, to: input)
        let output = directory.appendingPathComponent("paced.m4a")
        let chunks = OSAllocatedUnfairLock(initialState: 0)
        let pacer = NarrationPausePacer {
            chunks.withLock { $0 += 1 }
            withUnsafeCurrentTask { $0?.cancel() }
        }

        let task = Task { try await pacer.pace(input, to: output, targetDuration: inputDuration + 2) }
        await #expect(throws: CancellationError.self) { try await task.value }

        #expect(chunks.withLock { $0 } == 1)
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(PacerFixture.temporaryFiles(in: directory).isEmpty)
    }

    @Test func cancellationBeforeStartLeavesNoFile() async throws {
        let directory = try PacerFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.m4a")
        let inputDuration = try PacerFixture.write(Self.standard, to: input)
        let output = directory.appendingPathComponent("paced.m4a")

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await NarrationPausePacer().pace(input, to: output, targetDuration: inputDuration + 2)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(PacerFixture.temporaryFiles(in: directory).isEmpty)
    }
}

struct NarrationPausePlanTests {
    @Test func passageWithoutPausesGetsTrailingSilenceUpToItsCap() {
        let plan = NarrationPausePlan.insertions(silentRuns: [], totalFrames: 3_000, framesToAdd: 900, sampleRate: 1_000)
        #expect(plan == [NarrationPauseInsertion(position: 3_000, frames: 900)])
        let capped = NarrationPausePlan.insertions(silentRuns: [], totalFrames: 3_000, framesToAdd: 20_000, sampleRate: 1_000)
        #expect(capped == [NarrationPauseInsertion(position: 3_000, frames: Int(NarrationPausePlan.trailingCap * 1_000))])
    }

    @Test func everyCapIsHitAndLeadingSilenceIsSkipped() {
        let runs = [0..<1_000, 10_000..<12_000, 20_000..<30_000, 40_000..<44_100]
        let plan = NarrationPausePlan.insertions(
            silentRuns: runs, totalFrames: 44_100, framesToAdd: 1_000_000, sampleRate: 1_000
        )
        #expect(plan == [
            NarrationPauseInsertion(position: 11_000, frames: Int(NarrationPausePlan.interiorCap * 1_000)),
            NarrationPauseInsertion(position: 25_000, frames: Int(NarrationPausePlan.interiorCap * 1_000)),
            NarrationPauseInsertion(position: 44_100, frames: Int(NarrationPausePlan.trailingCap * 1_000)),
        ])
    }

    @Test(arguments: [0, -50])
    func nothingToAddPlansNothing(frames: Int) {
        let plan = NarrationPausePlan.insertions(
            silentRuns: [500..<900, 2_800..<3_000], totalFrames: 3_000, framesToAdd: frames, sampleRate: 1_000
        )
        #expect(plan.isEmpty)
    }

    @Test func sharesFollowPauseLengthAndTrailingWeighsAsMuchAsTheLongestPause() {
        let plan = NarrationPausePlan.insertions(
            silentRuns: [500..<900, 2_000..<2_150], totalFrames: 3_000, framesToAdd: 950, sampleRate: 1_000
        )
        #expect(plan == [
            NarrationPauseInsertion(position: 700, frames: 400),
            NarrationPauseInsertion(position: 2_075, frames: 150),
            NarrationPauseInsertion(position: 3_000, frames: 400),
        ])
    }

    @Test func pausesShorterThanTheMinimumAreIgnored() {
        let plan = NarrationPausePlan.insertions(
            silentRuns: [0..<50, 500..<600], totalFrames: 3_000, framesToAdd: 100, sampleRate: 1_000
        )
        #expect(plan == [NarrationPauseInsertion(position: 3_000, frames: 100)])
    }

    @Test func cappedPauseHandsItsExcessToTheOthers() throws {
        let plan = NarrationPausePlan.insertions(
            silentRuns: [1_000..<11_000, 12_000..<12_200], totalFrames: 20_000, framesToAdd: 9_000, sampleRate: 1_000
        )
        try #require(plan.count == 3)
        #expect(plan.map(\.position) == [6_000, 12_100, 20_000])
        #expect(plan[0].frames == Int(NarrationPausePlan.interiorCap * 1_000))
        #expect(plan[1].frames > 100 && plan[1].frames < 200)
        #expect(plan.map(\.frames).reduce(0, +) == 9_000)
    }

    // The largest case stays under the three caps combined (3 + 3 + 6 seconds).
    @Test(arguments: [1, 7, 101, 11_999])
    func roundingNeverExceedsTheBudget(frames: Int) {
        let plan = NarrationPausePlan.insertions(
            silentRuns: [300..<700, 1_700..<1_850, 2_850..<3_000], totalFrames: 3_000,
            framesToAdd: frames, sampleRate: 1_000
        )
        #expect(plan.map(\.frames).reduce(0, +) == frames)
    }
}

private enum PacerFixture {
    enum Piece {
        case silence(TimeInterval)
        case tone(TimeInterval)
    }

    struct Runs {
        var leading: TimeInterval = 0
        var speech: [TimeInterval] = []
        var gaps: [TimeInterval] = []
        var trailing: TimeInterval = 0
    }

    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NarrationPacerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func temporaryFiles(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasPrefix(".") }
    }

    /// Writes 0.5-amplitude tones with 5 ms ramps, so AAC smearing stays far below the measuring threshold.
    @discardableResult
    static func write(
        _ pieces: [Piece], to url: URL, rate: Double = 22_050, channels: AVAudioChannelCount = 1
    ) throws -> TimeInterval {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
        let writer = try NativeNarrationPCMWriter(outputURL: url, format: format)
        defer { writer.close() }
        var samples = [[Float]](repeating: [], count: Int(channels))
        for piece in pieces {
            switch piece {
            case .silence(let seconds):
                let count = Int((seconds * rate).rounded())
                for index in samples.indices { samples[index] += [Float](repeating: 0, count: count) }
            case .tone(let seconds):
                let count = Int((seconds * rate).rounded())
                let ramp = Int(0.005 * rate)
                for index in samples.indices {
                    let frequency = 440.0 * Double(index + 2) / 2
                    samples[index] += (0..<count).map { frame in
                        let envelope = Float(min(1, Double(min(frame, count - 1 - frame)) / Double(ramp)))
                        return 0.5 * envelope * Float(sin(2 * .pi * frequency * Double(frame) / rate))
                    }
                }
            }
        }
        var offset = 0
        let total = samples[0].count
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192))
        while offset < total {
            let count = min(8192, total - offset)
            for index in samples.indices {
                samples[index].withUnsafeBufferPointer {
                    buffer.floatChannelData![index].update(from: $0.baseAddress! + offset, count: count)
                }
            }
            buffer.frameLength = AVAudioFrameCount(count)
            try writer.append(buffer)
            offset += count
        }
        return Double(total) / rate
    }

    /// Classifies 10 ms windows with a fixed threshold, independently of the pacer's own detector.
    static func runs(_ url: URL, channel: Int? = nil) throws -> Runs {
        let file = try AVAudioFile(forReading: url)
        defer { file.close() }
        let rate = file.processingFormat.sampleRate
        let channelCount = Int(file.processingFormat.channelCount)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let window = Int(rate * 0.01)
        let frames = Int(buffer.frameLength)
        let selected = channel.map { [$0] } ?? Array(0..<channelCount)
        var speaking: [Bool] = []
        var start = 0
        while start < frames {
            let count = min(window, frames - start)
            var energy: Float = 0
            for index in selected {
                for frame in start..<(start + count) {
                    let sample = buffer.floatChannelData![index][frame]
                    energy += sample * sample
                }
            }
            speaking.append((energy / Float(count * selected.count)).squareRoot() > 0.05)
            start += count
        }
        var spans: [(speech: Bool, seconds: TimeInterval)] = []
        for (index, isSpeech) in speaking.enumerated() {
            let seconds = Double(min(window, frames - index * window)) / rate
            if let last = spans.last, last.speech == isSpeech {
                spans[spans.count - 1].seconds += seconds
            } else {
                spans.append((isSpeech, seconds))
            }
        }
        var result = Runs()
        if let first = spans.first, !first.speech { result.leading = first.seconds; spans.removeFirst() }
        if let last = spans.last, !last.speech { result.trailing = last.seconds; spans.removeLast() }
        result.speech = spans.filter(\.speech).map(\.seconds)
        result.gaps = spans.filter { !$0.speech }.map(\.seconds)
        return result
    }
}
