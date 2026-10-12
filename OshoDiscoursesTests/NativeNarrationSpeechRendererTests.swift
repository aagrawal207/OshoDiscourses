import AVFoundation
import Foundation
import Testing
@testable import OshoDiscourses

@Suite(.serialized)
struct NativeNarrationSpeechBufferTests {
    @Test func emptyAndSilentAudioAreNotSuccessfulNarration() async throws {
        let directory = try NarrationSpeechFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for silentFrames in [0, 4096] {
            let output = directory.appendingPathComponent("empty-\(silentFrames).m4a")
            let sink = NarrationSpeechBufferSink(outputURL: output)
            let buffer = try NarrationSpeechFixtures.buffer(frames: silentFrames, amplitude: 0)
            sink.receive(buffer)
            buffer.frameLength = 0
            sink.receive(buffer)
            await #expect(throws: NativeNarrationSpeechError.noAudio) { try await sink.value() }
            #expect(!FileManager.default.fileExists(atPath: output.path))
        }
    }

    @Test(arguments: [8_000.0, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000])
    func int16PCMUsesSupportedAACBitrateAtNativeRate(rate: Double) async throws {
        let directory = try NarrationSpeechFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("native-rate.m4a")
        let sink = NarrationSpeechBufferSink(outputURL: output)
        let frames = Int(rate * 0.15) + 17
        let buffer = try NarrationSpeechFixtures.buffer(rate: rate, commonFormat: .pcmFormatInt16, interleaved: true, frames: frames)
        sink.receive(buffer)
        buffer.frameLength = 0
        sink.receive(buffer)
        let duration = try await sink.value()
        let file = try AVAudioFile(forReading: output)
        defer { file.close() }
        #expect(file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
        #expect(file.processingFormat.sampleRate == rate)
        #expect(file.length == frames)
        #expect(abs(duration - Double(frames) / rate) < 1 / rate)
        #expect(try NarrationSpeechFixtures.energy(file, frequency: 440, at: 0.02) > 0.01)
    }

    @Test(arguments: [AVAudioCommonFormat.pcmFormatInt16, .pcmFormatInt32, .pcmFormatFloat32, .pcmFormatFloat64], [false, true])
    func stereoPCMIsConvertedWithoutReinterpretingSamples(commonFormat: AVAudioCommonFormat, interleaved: Bool) async throws {
        let directory = try NarrationSpeechFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("stereo.m4a")
        let sink = NarrationSpeechBufferSink(outputURL: output)
        let buffer = try NarrationSpeechFixtures.buffer(
            rate: 48_000, channels: 2, commonFormat: commonFormat, interleaved: interleaved, frames: 12_017
        )
        sink.receive(buffer)
        buffer.frameLength = 0
        sink.receive(buffer)
        let duration = try await sink.value()
        let file = try AVAudioFile(forReading: output)
        defer { file.close() }
        #expect(file.processingFormat.channelCount == 2)
        #expect(file.length == 12_017)
        #expect(abs(duration - 12_017.0 / 48_000) < 1 / 48_000.0)
        #expect(try NarrationSpeechFixtures.energy(file, frequency: 440, at: 0.04, channel: 0) > 0.01)
        #expect(try NarrationSpeechFixtures.energy(file, frequency: 880, at: 0.04, channel: 1) > 0.01)
        #expect(try NarrationSpeechFixtures.energy(file, frequency: 440, at: 0.04, channel: 1) < 0.001)
    }

    @Test func callbackCopiesBorrowedSamplesAndSplitsLargeBuffers() async throws {
        let directory = try NarrationSpeechFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("copied.m4a")
        let sink = NarrationSpeechBufferSink(outputURL: output)
        let buffer = try NarrationSpeechFixtures.buffer(frames: 100_003)
        sink.receive(buffer)
        buffer.floatChannelData![0].update(repeating: 0, count: Int(buffer.frameLength))
        buffer.frameLength = 0
        sink.receive(buffer)
        let duration = try await sink.value()
        let file = try AVAudioFile(forReading: output)
        defer { file.close() }
        #expect(file.length == 100_003)
        #expect(abs(duration - 100_003.0 / 22_050) < 1 / 22_050.0)
        #expect(try NarrationSpeechFixtures.energy(file, frequency: 440, at: duration - 0.15) > 0.01)
    }

    @Test func delegateFinishAndOneFrameBufferDoNotPrematurelySealAudio() async throws {
        let directory = try NarrationSpeechFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("finish-order.m4a")
        let sink = NarrationSpeechBufferSink(outputURL: output)
        sink.receive(try NarrationSpeechFixtures.buffer(frames: 1))
        sink.speechDidFinish()
        let buffer = try NarrationSpeechFixtures.buffer(frames: 8192)
        sink.receive(buffer)
        sink.receive(buffer)
        buffer.frameLength = 0
        sink.receive(buffer)
        sink.receive(buffer)
        let duration = try await sink.value()
        sink.speechDidFinish()
        sink.cancel()
        #expect(abs(duration - 16_385.0 / 22_050) < 1 / 22_050.0)
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    @Test func cancellationCleansPartialAndStaleCallbacksCannotTouchReplacement() async throws {
        let directory = try NarrationSpeechFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("replacement.m4a")
        let retired = NarrationSpeechBufferSink(outputURL: output)
        let buffer = try NarrationSpeechFixtures.buffer(frames: 20_000)
        retired.receive(buffer)
        retired.cancel()
        await #expect(throws: CancellationError.self) { try await retired.value() }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        let replacement = NarrationSpeechBufferSink(outputURL: output)
        replacement.receive(buffer)
        buffer.frameLength = 0
        replacement.receive(buffer)
        _ = try await replacement.value()
        let original = try Data(contentsOf: output)
        retired.receive(try NarrationSpeechFixtures.buffer(frames: 4096))
        retired.receive(buffer)
        retired.speechDidFinish()
        retired.cancel()
        #expect(try Data(contentsOf: output) == original)
    }

    @Test func cancellationBeforeStartAndTaskCancellationNeedNoNativeCallback() async throws {
        let directory = try NarrationSpeechFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let early = NarrationSpeechBufferSink(outputURL: directory.appendingPathComponent("early.m4a"))
        early.cancel()
        await #expect(throws: CancellationError.self) { try await early.value() }
        let sink = NarrationSpeechBufferSink(outputURL: directory.appendingPathComponent("task.m4a"))
        let task = Task { try await sink.value() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func stalledSynthesisTimesOut() async throws {
        let directory = try NarrationSpeechFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = NarrationSpeechBufferSink(outputURL: directory.appendingPathComponent("timeout.m4a"), inactivityTimeout: 0.03)
        await #expect(throws: NativeNarrationSpeechError.timedOut) { try await sink.value() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func missingEndMarkerAfterDelegateFinishFailsAndDeletesAudio() async throws {
        let directory = try NarrationSpeechFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = NarrationSpeechBufferSink(outputURL: directory.appendingPathComponent("unsealed.m4a"), finishTimeout: 0.03)
        sink.receive(try NarrationSpeechFixtures.buffer(frames: 4096))
        sink.speechDidFinish()
        await #expect(throws: NativeNarrationSpeechError.incompleteAudio) { try await sink.value() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func totalDeadlineBoundsEvenAStreamThatKeepsProducing() async throws {
        let directory = try NarrationSpeechFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = NarrationSpeechBufferSink(
            outputURL: directory.appendingPathComponent("endless.m4a"), inactivityTimeout: 1, totalTimeout: 0.06
        )
        let producer = Task {
            let buffer = try NarrationSpeechFixtures.buffer(frames: 4096)
            while !Task.isCancelled {
                sink.receive(buffer)
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        await #expect(throws: NativeNarrationSpeechError.timedOut) { try await sink.value() }
        producer.cancel()
        _ = await producer.result
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func changingFormatAndNonfinitePCMFailClosed() async throws {
        let directory = try NarrationSpeechFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let changed = NarrationSpeechBufferSink(outputURL: directory.appendingPathComponent("changed.m4a"))
        changed.receive(try NarrationSpeechFixtures.buffer(rate: 22_050, frames: 4096))
        changed.receive(try NarrationSpeechFixtures.buffer(rate: 48_000, frames: 4096))
        await #expect(throws: NativeNarrationSpeechError.formatChanged) { try await changed.value() }
        let invalid = NarrationSpeechBufferSink(outputURL: directory.appendingPathComponent("invalid.m4a"))
        let buffer = try NarrationSpeechFixtures.buffer(frames: 4096)
        buffer.floatChannelData![0][100] = .nan
        invalid.receive(buffer)
        await #expect(throws: NativeNarrationSpeechError.invalidBuffer) { try await invalid.value() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func nonPCMBuffersAndUnsupportedChannelsAreRejected() async throws {
        let directory = try NarrationSpeechFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let compressed = NarrationSpeechBufferSink(outputURL: directory.appendingPathComponent("compressed.m4a"))
        let format = try #require(AVAudioFormat(settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 22_050, AVNumberOfChannelsKey: 1]))
        compressed.receive(AVAudioCompressedBuffer(format: format, packetCapacity: 1, maximumPacketSize: 1024))
        await #expect(throws: NativeNarrationSpeechError.invalidBuffer) { try await compressed.value() }
        let surround = NarrationSpeechBufferSink(outputURL: directory.appendingPathComponent("surround.m4a"))
        surround.receive(try NarrationSpeechFixtures.buffer(channels: 3, frames: 4096))
        await #expect(throws: NativeNarrationSpeechError.unsupportedFormat) { try await surround.value() }
    }

    @Test func existingOutputAndFileCreationFailureLeaveNoUnownedChanges() async throws {
        let directory = try NarrationSpeechFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = directory.appendingPathComponent("existing.m4a")
        let sentinel = Data("existing owner".utf8)
        try sentinel.write(to: existing)
        let sink = NarrationSpeechBufferSink(outputURL: existing)
        sink.receive(try NarrationSpeechFixtures.buffer(frames: 4096))
        await #expect(throws: NativeNarrationSpeechError.outputExists) { try await sink.value() }
        #expect(try Data(contentsOf: existing) == sentinel)
        // A component beyond NAME_MAX forces file creation failure without changing directory permissions.
        let impossible = directory.appendingPathComponent(String(repeating: "x", count: 300) + ".m4a")
        let failed = NarrationSpeechBufferSink(outputURL: impossible)
        failed.receive(try NarrationSpeechFixtures.buffer(frames: 4096))
        await #expect(throws: (any Error).self) { try await failed.value() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["existing.m4a"])
    }
}

@MainActor
@Suite(.serialized)
struct NativeNarrationSpeechRendererTests {
    @Test func emptyTextUnavailableVoiceAndInvalidDestinationsAreExplicitFailures() async throws {
        let directory = try NarrationSpeechFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = NativeNarrationSpeechRenderer()
        let output = directory.appendingPathComponent("output.m4a")
        await #expect(throws: NativeNarrationSpeechError.emptyText) {
            try await renderer.render(text: " \n\t", voiceID: "missing", to: output)
        }
        await #expect(throws: NativeNarrationSpeechError.voiceUnavailable) {
            try await renderer.render(text: "A short sentence.", voiceID: "com.apple.voice.nonexistent.test", to: output)
        }
        await #expect(throws: NativeNarrationSpeechError.invalidOutput) {
            try await renderer.assemble(segments: [], to: directory.appendingPathComponent("output.wav"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func listedVoicesAreInstalledOrdinaryStableIDsSortedByQuality() {
        let voices = NativeNarrationSpeechRenderer.availableVoices()
        #expect(Set(voices.map(\.id)).count == voices.count)
        #expect(voices.map(\.quality) == voices.map(\.quality).sorted(by: >))
        for voice in voices {
            let native = AVSpeechSynthesisVoice(identifier: voice.id)
            #expect(native?.identifier == voice.id)
            #expect(native?.voiceTraits.contains(.isPersonalVoice) == false)
            #expect(native?.voiceTraits.contains(.isNoveltyVoice) == false)
            #expect(voice.id.hasPrefix("com.apple."))
            #expect(native?.language == voice.language)
        }
    }

    @Test(arguments: ["empty-list", "missing", "garbage", "empty-file", "truncated"])
    func assemblyRejectsIncompleteInputs(kind: String) async throws {
        let directory = try NarrationSpeechFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let segment = directory.appendingPathComponent("segment.m4a")
        switch kind {
        case "garbage": try Data("not audio".utf8).write(to: segment)
        case "empty-file": try Data().write(to: segment)
        case "truncated":
            try NarrationSpeechFixtures.writeAAC(to: segment, seconds: 0.3)
            let handle = try FileHandle(forWritingTo: segment)
            try handle.truncate(atOffset: 32)
            try handle.close()
        default: break
        }
        let output = directory.appendingPathComponent("assembled.m4a")
        await #expect(throws: (any Error).self) {
            try await NativeNarrationSpeechRenderer().assemble(segments: kind == "empty-list" ? [] : [segment], to: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try !FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".narration-") })
    }

    @Test func assemblyPreservesOrderAndMeasuredDurationAcrossNativeFormats() async throws {
        let directory = try NarrationSpeechFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.m4a")
        let second = directory.appendingPathComponent("second.m4a")
        try NarrationSpeechFixtures.writeAAC(to: first, rate: 22_050, seconds: 0.3, frequency: 330)
        try NarrationSpeechFixtures.writeAAC(to: second, rate: 48_000, channels: 2, seconds: 0.4, frequency: 660)
        let output = directory.appendingPathComponent("assembled.m4a")
        let duration = try await NativeNarrationSpeechRenderer().assemble(segments: [first, second, first], to: output)
        let assetDuration = try await AVURLAsset(url: output).load(.duration).seconds
        #expect(abs(duration - 1) < 0.002)
        #expect(abs(duration - assetDuration) < 0.002)
        let file = try AVAudioFile(forReading: output)
        defer { file.close() }
        for (time, frequency, other) in [(0.1, 330.0, 660.0), (0.4, 660.0, 330.0), (0.8, 330.0, 660.0)] {
            #expect(try NarrationSpeechFixtures.energy(file, frequency: frequency, at: time) > 0.01)
            #expect(try NarrationSpeechFixtures.energy(file, frequency: other, at: time) < 0.002)
        }
    }

    @Test func aThousandSegmentsKeepTheirFullTimeline() async throws {
        let directory = try NarrationSpeechFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let segment = directory.appendingPathComponent("paragraph.m4a")
        try NarrationSpeechFixtures.writeAAC(to: segment, rate: 44_100, seconds: 0.02)
        let output = directory.appendingPathComponent("thousand.m4a")
        let duration = try await NativeNarrationSpeechRenderer().assemble(segments: Array(repeating: segment, count: 1000), to: output)
        #expect(abs(duration - 20) < 0.01)
        #expect(try await AVURLAsset(url: output).load(.isPlayable))
    }

    @Test func overlappingOperationsAreRejectedAndExplicitCancellationCleansUp() async throws {
        let directory = try NarrationSpeechFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let segment = directory.appendingPathComponent("paragraph.m4a")
        try NarrationSpeechFixtures.writeAAC(to: segment, seconds: 0.02)
        let renderer = NativeNarrationSpeechRenderer()
        let output = directory.appendingPathComponent("cancelled.m4a")
        let job = Task { try await renderer.assemble(segments: Array(repeating: segment, count: 1000), to: output) }
        try await Task.sleep(for: .milliseconds(10))
        await #expect(throws: NativeNarrationSpeechError.busy) {
            try await renderer.render(text: "A sentence.", voiceID: "missing", to: directory.appendingPathComponent("overlap.m4a"))
        }
        renderer.cancel()
        await #expect(throws: CancellationError.self) { try await job.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["paragraph.m4a"])
        let replacement = directory.appendingPathComponent("replacement.m4a")
        #expect(try await renderer.assemble(segments: [segment], to: replacement) > 0)
    }

    @Test func callerCancellationAndExistingOutputPreserveInputs() async throws {
        let directory = try NarrationSpeechFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let segment = directory.appendingPathComponent("paragraph.m4a")
        try NarrationSpeechFixtures.writeAAC(to: segment, seconds: 0.2)
        let original = try Data(contentsOf: segment)
        let renderer = NativeNarrationSpeechRenderer()
        await #expect(throws: NativeNarrationSpeechError.outputExists) {
            try await renderer.assemble(segments: [segment], to: segment)
        }
        let task = Task {
            try await renderer.assemble(segments: Array(repeating: segment, count: 1000), to: directory.appendingPathComponent("cancelled.m4a"))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: segment) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["paragraph.m4a"])
    }
}

private enum NarrationSpeechFixtures {
    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NarrationSpeechTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func buffer(
        rate: Double = 22_050, channels: AVAudioChannelCount = 1,
        commonFormat: AVAudioCommonFormat = .pcmFormatFloat32, interleaved: Bool = false,
        frames: Int, frequency: Double = 440, amplitude: Double = 0.25
    ) throws -> AVAudioPCMBuffer {
        let format: AVAudioFormat
        if channels <= 2 {
            format = try #require(AVAudioFormat(commonFormat: commonFormat, sampleRate: rate, channels: channels, interleaved: interleaved))
        } else {
            let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels))
            format = AVAudioFormat(commonFormat: commonFormat, sampleRate: rate, interleaved: interleaved, channelLayout: layout)
        }
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, frames))))
        buffer.frameLength = AVAudioFrameCount(frames)
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for channel in 0..<Int(channels) {
            let data = try #require(buffers[interleaved ? 0 : channel].mData)
            for frame in 0..<frames {
                let index = interleaved ? frame * Int(channels) + channel : frame
                let sample = sin(Double(frame) * 2 * .pi * frequency * Double(channel + 1) / rate) * amplitude
                switch commonFormat {
                case .pcmFormatFloat32: data.assumingMemoryBound(to: Float.self)[index] = Float(sample)
                case .pcmFormatFloat64: data.assumingMemoryBound(to: Double.self)[index] = sample
                case .pcmFormatInt16: data.assumingMemoryBound(to: Int16.self)[index] = Int16(sample * Double(Int16.max))
                case .pcmFormatInt32: data.assumingMemoryBound(to: Int32.self)[index] = Int32(sample * Double(Int32.max))
                default: throw NativeNarrationSpeechError.unsupportedFormat
                }
            }
        }
        return buffer
    }

    static func writeAAC(to url: URL, rate: Double = 22_050, channels: AVAudioChannelCount = 1, seconds: Double, frequency: Double = 440) throws {
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: Int(channels),
        ])
        defer { file.close() }
        let buffer = try buffer(rate: rate, channels: channels, frames: Int(rate * seconds), frequency: frequency)
        for channel in 1..<Int(channels) {
            buffer.floatChannelData![channel].update(from: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        }
        try file.write(from: buffer)
    }

    static func energy(_ file: AVAudioFile, frequency: Double, at time: Double, channel: Int = 0) throws -> Double {
        let rate = file.processingFormat.sampleRate
        file.framePosition = AVAudioFramePosition(time * rate)
        let count = min(AVAudioFramePosition(rate * 0.08), file.length - file.framePosition)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)))
        try file.read(into: buffer)
        let samples = try #require(buffer.floatChannelData)[channel]
        var real = 0.0
        var imaginary = 0.0
        for frame in 0..<Int(buffer.frameLength) {
            let angle = Double(frame) * 2 * .pi * frequency / rate
            real += Double(samples[frame]) * cos(angle)
            imaginary += Double(samples[frame]) * sin(angle)
        }
        return (real * real + imaginary * imaginary) / pow(Double(buffer.frameLength), 2)
    }
}
