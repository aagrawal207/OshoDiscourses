import AVFoundation
import Testing
@testable import OshoDiscourses

struct NoiseReductionProcessorTests {
    @Test func cadenceAttenuatesMainsHum() {
        let sampleRate = 48_000.0
        let input = sineWave(frequency: 60, sampleRate: sampleRate, seconds: 1)
        let output = processCadence(input, sampleRate: sampleRate)

        #expect(rms(Array(output.suffix(output.count / 2))) < rms(input) * 0.35)
    }

    @Test func cadencePreservesVoiceBandTone() {
        let sampleRate = 48_000.0
        let input = sineWave(frequency: 440, sampleRate: sampleRate, seconds: 1)
        let output = processCadence(input, sampleRate: sampleRate)

        #expect(rms(Array(output.suffix(output.count / 2))) > rms(input) * 0.8)
    }

    @Test func rnnoiseDrySignalUsesMatchingDelayedFrame() {
        let processor = NoiseReductionProcessor()
        processor.configure(mode: .rnnoise, wetMix: 0, intensity: 1, attenuationLimitDb: 100, voiceFocus: .focus)
        processor.prepare(channelCount: 1, maxFrames: 480, sampleRate: 48_000)

        var first = [Float](repeating: 0, count: 480)
        first[0] = 1
        var second = [Float](repeating: 0, count: 480)
        var third = [Float](repeating: 0, count: 480)
        var fourth = [Float](repeating: 0, count: 480)
        process(&first, with: processor)
        process(&second, with: processor)
        process(&third, with: processor)
        process(&fourth, with: processor)

        #expect(first.allSatisfy { abs($0) < 0.0001 })
        #expect(second.allSatisfy { abs($0) < 0.0001 })
        #expect(third.allSatisfy { abs($0) < 0.0001 })
        #expect(abs(fourth[0] - 1) < 0.0001)
    }

    @Test func rnnoiseWetAndDryHaveTheSameMeasuredDelay() {
        let rate = 48_000.0
        let count = 48_000
        var state: UInt64 = 17
        let signal = (0..<count).map { _ -> Float in
            state = state &* 6364136223846793005 &+ 1
            return Float(Double(state >> 32) / Double(UInt32.max) - 0.5) * 0.3
        }
        func render(wet: Float) -> [Float] {
            let processor = NoiseReductionProcessor()
            processor.configure(mode: .rnnoise, wetMix: wet, intensity: 1, attenuationLimitDb: 12, voiceFocus: .focus)
            processor.prepare(channelCount: 1, maxFrames: 1024, sampleRate: rate)
            var output: [Float] = []
            for offset in stride(from: 0, to: count, by: 1024) {
                var block = Array(signal[offset..<min(count, offset + 1024)])
                process(&block, with: processor)
                output += block
            }
            return output
        }
        func lag(_ output: [Float]) -> Int {
            var best = -Double.infinity
            var result = 0
            for delay in 0..<2000 {
                var dot = 0.0
                for index in stride(from: 0, to: count - 2000, by: 7) {
                    dot += Double(signal[index]) * Double(output[index + delay])
                }
                if dot > best { best = dot; result = delay }
            }
            return result
        }
        let dryLag = lag(render(wet: 0))
        let wetLag = lag(render(wet: 1))
        #expect(wetLag == 1440, "one buffered hop plus the vendored model's two-hop lookahead")
        #expect(dryLag == wetLag, "misaligned blending comb-filters speech")
    }

    @Test func rnnoiseInterleavedStereoMatchesPlanarProcessing() {
        let rate = 22_050.0
        let frames = 4096
        func processor() -> NoiseReductionProcessor {
            let p = NoiseReductionProcessor()
            p.configure(mode: .rnnoise, wetMix: 0.5, intensity: 1, attenuationLimitDb: 12, voiceFocus: .focus)
            p.prepare(channelCount: 2, maxFrames: frames, sampleRate: rate)
            return p
        }
        let planarProcessor = processor()
        let interleavedProcessor = processor()
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let planar = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        planar.frameLength = AVAudioFrameCount(frames)
        for pass in 0..<4 {
            var interleaved = [Float](repeating: 0, count: frames * 2)
            for frame in 0..<frames {
                let t = Double(pass * frames + frame) / rate
                let left = Float(0.25 * sin(2 * .pi * 237 * t))
                let right = Float(0.15 * sin(2 * .pi * 419 * t))
                planar.floatChannelData![0][frame] = left
                planar.floatChannelData![1][frame] = right
                interleaved[frame * 2] = left
                interleaved[frame * 2 + 1] = right
            }
            planarProcessor.process(buffer: planar.mutableAudioBufferList, frameCount: planar.frameLength)
            interleaved.withUnsafeMutableBytes { bytes in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress
                ))
                interleavedProcessor.process(buffer: &list, frameCount: UInt32(frames))
            }
            for lane in 0..<2 {
                let error = (0..<frames).map { abs(interleaved[$0 * 2 + lane] - planar.floatChannelData![lane][$0]) }.max()!
                #expect(error < 0.00001)
            }
        }
    }

    @Test func shortBufferIsLeftUntouchedInsteadOfReadingPastItsEnd() {
        let processor = NoiseReductionProcessor()
        processor.prepare(channelCount: 1, maxFrames: 1024, sampleRate: 48_000)
        var samples: [Float] = [0.1, -0.2, 0.3]
        let original = samples
        samples.withUnsafeMutableBytes { bytes in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 1, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress
            ))
            processor.process(buffer: &list, frameCount: 1024)
        }
        #expect(samples == original)
        let diagnostics = processor.diagnosticsSnapshot()
        #expect(diagnostics.invalidBuffers == 1)
        #expect(diagnostics.processedBuffers == 0)
        #expect(diagnostics.modelBypassedBuffers == 0)
    }

    @Test func diagnosticsDistinguishProcessedDisabledAndUnpreparedAudio() {
        let processor = NoiseReductionProcessor()
        var input = [Float](repeating: 0.2, count: 480)
        process(&input, with: processor)
        processor.configure(mode: .cadence, wetMix: 0.5, intensity: 0.7, attenuationLimitDb: 12, voiceFocus: .focus)
        processor.prepare(channelCount: 1, maxFrames: 480, sampleRate: 48_000)
        process(&input, with: processor)
        processor.setDenoiseEnabled(false)
        process(&input, with: processor)
        let diagnostics = processor.diagnosticsSnapshot()
        #expect(diagnostics.processedBuffers == 1)
        #expect(diagnostics.disabledBuffers == 1)
        #expect(diagnostics.unpreparedBuffers == 1)
        #expect(diagnostics.invalidBuffers == 0)
        #expect(diagnostics.modelBypassedBuffers == 0)
        #expect(diagnostics.lockContendedBuffers == 0)
    }

    @Test(arguments: [22_050.0, 32_000, 44_100, 48_000])
    func rnnoiseNeverClipsAFullScaleRecording(sampleRate: Double) {
        let processor = NoiseReductionProcessor()
        processor.configure(mode: .rnnoise, wetMix: 0.5, intensity: 1, attenuationLimitDb: 12, voiceFocus: .focus)
        processor.prepare(channelCount: 1, maxFrames: 1024, sampleRate: sampleRate)
        for pass in 0..<100 {
            var samples = (0..<1024).map { index in
                let t = Double(pass * 1024 + index) / sampleRate
                let harmonics = sin(2 * .pi * 237 * t) + 0.5 * sin(2 * .pi * 474 * t)
                return Float(max(-1, min(1, harmonics)))
            }
            process(&samples, with: processor)
            #expect(samples.allSatisfy { $0.isFinite && abs($0) <= 1 })
        }
    }

    private func processCadence(_ input: [Float], sampleRate: Double) -> [Float] {
        let processor = NoiseReductionProcessor()
        processor.configure(mode: .cadence, wetMix: 0, intensity: 1, attenuationLimitDb: 100, voiceFocus: .focus)
        processor.prepare(channelCount: 1, maxFrames: input.count, sampleRate: sampleRate)
        var output = input
        process(&output, with: processor)
        return output
    }

    private func process(_ samples: inout [Float], with processor: NoiseReductionProcessor) {
        let frameCount = UInt32(samples.count)
        samples.withUnsafeMutableBytes { bytes in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(bytes.count),
                    mData: bytes.baseAddress
                )
            )
            withUnsafeMutablePointer(to: &list) {
                processor.process(buffer: $0, frameCount: frameCount)
            }
        }
    }

    private func sineWave(frequency: Double, sampleRate: Double, seconds: Double) -> [Float] {
        let count = Int(sampleRate * seconds)
        return (0..<count).map { index in
            Float(0.2 * sin(2 * Double.pi * frequency * Double(index) / sampleRate))
        }
    }

    private func rms(_ samples: [Float]) -> Float {
        sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
    }
}
