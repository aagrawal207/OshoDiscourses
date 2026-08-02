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
        process(&first, with: processor)
        process(&second, with: processor)
        process(&third, with: processor)

        #expect(first.allSatisfy { abs($0) < 0.0001 })
        #expect(second.allSatisfy { abs($0) < 0.0001 })
        #expect(abs(third[0] - 1) < 0.0001)
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
