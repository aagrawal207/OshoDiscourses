import AVFoundation
import Testing
@testable import OshoDiscourses

struct DeepFilterLifecycleTests {
    @Test func loadingInstallsTheLatestStrengthAndFocus() async throws {
        let changed = DeepFilterProcessor()
        changed.setAttenuationLimit(6)
        changed.activate(channelCount: 1, maxFrames: 1024, sampleRate: 22_050)
        changed.setAttenuationLimit(100)
        changed.setVoiceFocus(.strong)

        let reference = DeepFilterProcessor()
        reference.setAttenuationLimit(100)
        reference.setVoiceFocus(.strong)
        reference.activate(channelCount: 1, maxFrames: 1024, sampleRate: 22_050)
        try await wait(changed)
        try await wait(reference)

        for pass in 0..<60 {
            var expected = (0..<1024).map { index -> Float in
                let t = Double(pass * 1024 + index) / 22_050
                return Float(0.015 * sin(2 * .pi * 217 * t) + 0.009 * sin(2 * .pi * 431 * t))
            }
            var actual = expected
            #expect(changed.process(samples: &actual, count: actual.count, channelIndex: 0))
            #expect(reference.process(samples: &expected, count: expected.count, channelIndex: 0))
            let difference = zip(actual, expected).map { abs($0 - $1) }.max() ?? 0
            #expect(difference < 0.00001, "a setting changed while loading was not applied to audio")
        }
    }

    @Test func invalidatingAnInFlightLoadPreventsReactivation() async throws {
        let processor = DeepFilterProcessor()
        processor.activate(channelCount: 1, maxFrames: 1024, sampleRate: 48_000)
        processor.invalidate()
        try await Task.sleep(for: .seconds(2))
        #expect(processor.currentStatus == .idle)
        var input = [Float](repeating: 0.2, count: 480)
        #expect(!processor.process(samples: &input, count: input.count, channelIndex: 0))
        #expect(input.allSatisfy { $0 == 0.2 })
    }

    @Test func unsupportedPCMFormatCancelsAnOlderLoad() async throws {
        let processor = NoiseReductionProcessor()
        processor.configure(mode: .deepFilterNet, wetMix: 0.5, intensity: 0.7, attenuationLimitDb: 12, voiceFocus: .focus)
        processor.prepare(channelCount: 1, maxFrames: 480, sampleRate: 48_000)
        processor.prepare(channelCount: 1, maxFrames: 480, sampleRate: 48_000, isFloat32PCM: false)
        try await Task.sleep(for: .seconds(2))
        #expect(processor.deepFilter.currentStatus == .unsupportedAudioFormat)
        #expect(processor.deepFilter.currentStatus.isBypassing)
        var samples = [Float](repeating: 0.2, count: 480)
        process(&samples, with: processor)
        #expect(samples.allSatisfy { $0 == 0.2 })
        #expect(processor.diagnosticsSnapshot().unpreparedBuffers == 1)
    }

    @Test func changingOnlyConfigurationDoesNotResetTheAudioStream() async throws {
        func makeProcessor() -> NoiseReductionProcessor {
            let processor = NoiseReductionProcessor()
            processor.configure(mode: .deepFilterNet, wetMix: 0.5, intensity: 0.7, attenuationLimitDb: 12, voiceFocus: .focus)
            processor.prepare(channelCount: 1, maxFrames: 480, sampleRate: 48_000)
            return processor
        }
        let changed = makeProcessor()
        let reference = makeProcessor()
        try await wait(changed.deepFilter)
        try await wait(reference.deepFilter)
        for pass in 0..<100 {
            if pass == 40 {
                changed.configure(mode: .deepFilterNet, wetMix: 0.5, intensity: 0.7, attenuationLimitDb: 12, voiceFocus: .focus)
            }
            var expected = (0..<480).map { index in
                Float(0.2 * sin(2 * .pi * 317 * Double(pass * 480 + index) / 48_000))
            }
            var actual = expected
            process(&actual, with: changed)
            process(&expected, with: reference)
            let difference = zip(actual, expected).map { abs($0 - $1) }.max() ?? 0
            #expect(difference < 0.00001, "configuration inserted a fresh priming gap")
        }
    }

    @Test func interleavedDeepFilterAudioIsDenoisedAndRemainsMono() async throws {
        let processor = NoiseReductionProcessor()
        processor.configure(mode: .deepFilterNet, wetMix: 0.5, intensity: 0.7, attenuationLimitDb: 12, voiceFocus: .focus)
        processor.prepare(channelCount: 2, maxFrames: 1024, sampleRate: 22_050)
        try await wait(processor.deepFilter)
        for pass in 0..<10 {
            var input = (0..<2048).map { index in
                Float(index.isMultiple(of: 2) ? 0.2 : 0.1) * sin(Float(index / 2 + pass * 1024) * 0.1)
            }
            input.withUnsafeMutableBytes { bytes in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress
                ))
                processor.process(buffer: &list, frameCount: 1024)
            }
            #expect((0..<1024).allSatisfy { input[$0 * 2] == input[$0 * 2 + 1] })
            #expect(input.allSatisfy { $0.isFinite })
        }
    }

    private func wait(_ processor: DeepFilterProcessor) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !processor.currentStatus.isActive, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(processor.currentStatus.isActive)
    }

    private func process(_ samples: inout [Float], with processor: NoiseReductionProcessor) {
        let count = UInt32(samples.count)
        samples.withUnsafeMutableBytes { bytes in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 1, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress
            ))
            processor.process(buffer: &list, frameCount: count)
        }
    }
}
