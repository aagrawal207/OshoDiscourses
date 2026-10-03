import AVFoundation
import CoreAudio
import Synchronization
import Testing
@testable import OshoDiscourses

struct NoiseDiscontinuityTests {
    @Test(arguments: [NoiseReductionMode.rnnoise, .cadence, .deepFilterNet])
    func firstStartFlagDoesNotAddAResetOrBypass(mode: NoiseReductionMode) async throws {
        let processor = try await ready(mode: mode)
        let reference = try await ready(mode: mode)
        let actual = buffer(channels: 1)
        let expected = buffer(channels: 1)
        fill(actual)
        fill(expected)
        let result = source(actual, processor: processor, flags: kMTAudioProcessingTapFlag_StartOfStream)
        _ = source(expected, processor: reference)
        #expect(result.frames == Int(actual.frameLength))
        #expect(result.flags == kMTAudioProcessingTapFlag_StartOfStream)
        #expect(maxDifference(contents(actual), contents(expected)) < 0.00001)
        let diagnostics = processor.diagnosticsSnapshot()
        #expect(diagnostics.sourceDiscontinuities == 1)
        #expect(diagnostics.streamResets == 0)
        #expect(diagnostics.processedBuffers == 1)
        #expect(diagnostics.resetBypassedBuffers == 0)
        #expect(!diagnostics.resetPending)
    }

    @Test(arguments: [NoiseReductionMode.rnnoise, .cadence, .deepFilterNet], [false, true])
    func sourceBoundaryDiscardsAllPreviousChannelAudio(mode: NoiseReductionMode, interleaved: Bool) async throws {
        let processor = try await ready(mode: mode, channels: 2)
        let block = buffer(channels: 2, interleaved: interleaved)
        for index in 0..<20 {
            fill(block, offset: index * 1024)
            _ = source(block, processor: processor)
        }
        fill(block, silent: true)
        let result = source(block, processor: processor, flags: kMTAudioProcessingTapFlag_StartOfStream)
        #expect(result.frames == 1024)
        #expect(contents(block).allSatisfy { $0 == 0 }, "the boundary must not emit an old FIFO")
        try await waitForReset(processor)
        for _ in 0..<10 {
            fill(block, silent: true)
            _ = source(block, processor: processor)
            #expect(contents(block).allSatisfy { $0.isFinite && abs($0) < 0.0001 })
        }
        let diagnostics = processor.diagnosticsSnapshot()
        #expect(diagnostics.sourceDiscontinuities == 1)
        #expect(diagnostics.streamResets == 1)
        #expect(diagnostics.resetBypassedBuffers == 1)
    }

    @Test(arguments: [NoiseReductionMode.rnnoise, .deepFilterNet])
    func failedSourceReadReturnsNoAudioAndRecoveryDiscardsHistory(mode: NoiseReductionMode) async throws {
        let processor = try await ready(mode: mode, channels: 2)
        let block = buffer(channels: 2, interleaved: true)
        for index in 0..<12 {
            fill(block, offset: index * 1024)
            _ = source(block, processor: processor)
        }
        fill(block, offset: 20_000)
        let original = contents(block)
        let failed = source(block, processor: processor, flags: kMTAudioProcessingTapFlag_StartOfStream, status: -50)
        #expect(failed.frames == 0)
        #expect(failed.flags == 0)
        #expect(contents(block) == original, "failed-read storage is undefined and must not be processed")
        try await waitForReset(processor)
        var diagnostics = processor.diagnosticsSnapshot()
        #expect(diagnostics.sourceReadFailures == 1)
        #expect(diagnostics.sourceReadFailed)
        #expect(diagnostics.sourceDiscontinuities == 0, "failed-read flags are undefined")
        for _ in 0..<8 {
            fill(block, silent: true)
            _ = source(block, processor: processor)
            #expect(contents(block).allSatisfy { abs($0) < 0.0001 })
        }
        diagnostics = processor.diagnosticsSnapshot()
        #expect(!diagnostics.sourceReadFailed)
        #expect(diagnostics.streamResets == 1)
    }

    @Test func malformedSuccessfulReadCannotExposeOldBufferMemory() async throws {
        let processor = try await ready(mode: .cadence)
        let block = buffer(channels: 1)
        fill(block)
        let original = contents(block)
        for count in [-1, 1025] {
            let result = source(block, processor: processor, returnedFrames: count)
            #expect(result.frames == 0)
            #expect(result.flags == 0)
            #expect(contents(block) == original)
        }
        #expect(processor.diagnosticsSnapshot().sourceReadFailures == 2)
    }

    @Test(arguments: [NoiseReductionMode.rnnoise, .deepFilterNet])
    func repeatedEmptyStartBoundariesKeepLatencyBounded(mode: NoiseReductionMode) async throws {
        let processor = try await ready(mode: mode, maxFrames: 4096)
        let fixture = DeepFilterNetTests()
        let signal = fixture.syllables(seconds: 2, sampleRate: 22_050)
        var firstLag = 0
        let boundary = buffer(channels: 1)
        boundary.frameLength = 0
        for iteration in 0...12 {
            if iteration > 0 {
                let result = source(boundary, processor: processor, flags: kMTAudioProcessingTapFlag_StartOfStream)
                #expect(result.frames == 0)
                try await waitForReset(processor)
            }
            let output = render(signal, processor: processor)
            let lag = fixture.bestLag(reference: signal, rendered: output, maxLag: 2205)
            if iteration == 0 { firstLag = lag }
            #expect(abs(lag - firstLag) <= 1, "latency grew from \(firstLag) to \(lag) after \(iteration) boundaries")
            #expect(lag > 0 && lag < 2205)
        }
        #expect(processor.diagnosticsSnapshot().streamResets == 12)
        #expect(!processor.diagnosticsSnapshot().resetPending)
    }

    @Test(arguments: [false, true])
    func laterChannelFailureLeavesTheEntireBufferRaw(interleaved: Bool) async throws {
        let processor = NoiseReductionProcessor(rnnoiseFactory: { rate, frames, channel in
            RNNoiseProcessor(sourceRate: rate, maxFrames: channel == 0 ? frames : 480)
        })
        processor.configure(mode: .rnnoise, wetMix: 0.5, intensity: 0.7,
                            attenuationLimitDb: 12, voiceFocus: .focus, outputGain: 4)
        processor.prepare(channelCount: 2, maxFrames: 1024, sampleRate: 22_050)
        let failed = buffer(channels: 2, interleaved: interleaved)
        fill(failed)
        let original = contents(failed)
        let result = source(failed, processor: processor)
        #expect(result.frames == 1024)
        #expect(contents(failed) == original, "no partial denoising, downmix or boost may escape")
        try await waitForReset(processor)
        #expect(processor.diagnosticsSnapshot().modelBypassedBuffers == 1)
        #expect(processor.diagnosticsSnapshot().processedBuffers == 0)

        let reference = try await ready(mode: .rnnoise, channels: 2, maxFrames: 1024, gain: 4)
        let actual = buffer(channels: 2, frames: 480, interleaved: interleaved)
        let expected = buffer(channels: 2, frames: 480, interleaved: interleaved)
        for index in 0..<12 {
            fill(actual, offset: index * 480)
            fill(expected, offset: index * 480)
            _ = source(actual, processor: processor)
            _ = source(expected, processor: reference)
            #expect(maxDifference(contents(actual), contents(expected)) < 0.00001)
            #expect(contents(actual).allSatisfy { $0.isFinite && abs($0) <= 1 })
        }
    }

    @Test func sourceBoundaryNeverWaitsForTheControlLock() throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let prepared = DispatchSemaphore(value: 0)
        let rendered = DispatchSemaphore(value: 0)
        let raw = Mutex(false)
        let processor = NoiseReductionProcessor(rnnoiseFactory: { rate, frames, _ in
            entered.signal()
            release.wait()
            return RNNoiseProcessor(sourceRate: rate, maxFrames: frames)
        })
        DispatchQueue.global().async {
            processor.prepare(channelCount: 1, maxFrames: 1024, sampleRate: 22_050)
            prepared.signal()
        }
        try #require(entered.wait(timeout: .now() + 5) == .success)
        DispatchQueue.global().async {
            var samples = [Float](repeating: 0.25, count: 1024)
            samples.withUnsafeMutableBytes { bytes in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress
                ))
                processor.process(buffer: &list, frameCount: 1024, sourceFlags: kMTAudioProcessingTapFlag_StartOfStream)
            }
            raw.withLock { $0 = samples.allSatisfy { $0 == 0.25 } }
            rendered.signal()
        }
        let completedWithoutControlLock = rendered.wait(timeout: .now() + 0.5) == .success
        release.signal()
        #expect(prepared.wait(timeout: .now() + 5) == .success)
        #expect(completedWithoutControlLock, "render callback blocked on preparation/reset")
        if !completedWithoutControlLock { _ = rendered.wait(timeout: .now() + 5) }
        #expect(raw.withLock { $0 })
        #expect(processor.diagnosticsSnapshot().lockContendedBuffers == 1)
    }

    private func render(_ signal: [Float], processor: NoiseReductionProcessor) -> [Float] {
        var output: [Float] = []
        for offset in stride(from: 0, to: signal.count, by: 4096) {
            let count = min(4096, signal.count - offset)
            let block = buffer(channels: 1, frames: UInt32(count))
            block.floatChannelData![0].update(from: Array(signal[offset..<offset + count]), count: count)
            _ = source(block, processor: processor)
            output += contents(block)
        }
        return output
    }

    private func ready(
        mode: NoiseReductionMode, channels: Int = 1, maxFrames: Int = 1024, gain: Float = 1
    ) async throws -> NoiseReductionProcessor {
        let processor = NoiseReductionProcessor()
        processor.configure(mode: mode, wetMix: 0.5, intensity: 0.7,
                            attenuationLimitDb: 12, voiceFocus: .focus, outputGain: gain)
        processor.prepare(channelCount: channels, maxFrames: maxFrames, sampleRate: 22_050)
        if mode == .deepFilterNet {
            let deadline = ContinuousClock.now + .seconds(20)
            while !processor.deepFilter.currentStatus.isActive, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(processor.deepFilter.currentStatus.isActive)
        }
        return processor
    }

    private func waitForReset(_ processor: NoiseReductionProcessor) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while processor.diagnosticsSnapshot().resetPending, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(!processor.diagnosticsSnapshot().resetPending)
    }

    private func buffer(channels: UInt32, frames: UInt32 = 1024, interleaved: Bool = false) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 22_050,
                                   channels: channels, interleaved: interleaved)!
        let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        block.frameLength = frames
        return block
    }

    private func fill(_ block: AVAudioPCMBuffer, offset: Int = 0, silent: Bool = false) {
        var channel = 0
        for part in UnsafeMutableAudioBufferListPointer(block.mutableAudioBufferList) {
            let pointer = part.mData!.assumingMemoryBound(to: Float.self)
            let channels = Int(part.mNumberChannels)
            for lane in 0..<channels {
                for frame in 0..<Int(block.frameLength) {
                    pointer[frame * channels + lane] = silent ? 0 : Float(
                        (channel == 0 ? 0.7 : 0.4) * sin(Double(offset + frame) * (channel == 0 ? 0.071 : 0.107))
                    )
                }
                channel += 1
            }
        }
    }

    private func contents(_ block: AVAudioPCMBuffer) -> [Float] {
        UnsafeMutableAudioBufferListPointer(block.mutableAudioBufferList).flatMap { part in
            Array(UnsafeBufferPointer(start: part.mData!.assumingMemoryBound(to: Float.self),
                                      count: Int(block.frameLength * part.mNumberChannels)))
        }
    }

    private func source(
        _ block: AVAudioPCMBuffer, processor: NoiseReductionProcessor,
        flags: MTAudioProcessingTapFlags = 0, status: OSStatus = noErr, returnedFrames: Int? = nil
    ) -> (frames: Int, flags: MTAudioProcessingTapFlags) {
        var count = returnedFrames ?? Int(block.frameLength)
        var outputFlags = flags
        processor.processSourceAudio(buffer: block.mutableAudioBufferList, requestedFrames: Int(block.frameCapacity),
                                     returnedFrames: &count, flags: &outputFlags, status: status)
        return (count, outputFlags)
    }

    private func maxDifference(_ lhs: [Float], _ rhs: [Float]) -> Float {
        zip(lhs, rhs).map { abs($0 - $1) }.max() ?? 0
    }
}
