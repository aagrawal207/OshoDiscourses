import Foundation
import Testing
@testable import OshoDiscourses

/// The resampler is what lets the 48 kHz neural model run on this 22,050 Hz
/// archive at all, so its correctness is load-bearing for the whole feature.
struct PolyphaseResamplerTests {

    @Test func reducesRatioToLowestTerms() {
        let up = PolyphaseResampler(inputRate: 22_050, outputRate: 48_000, maxInputFrames: 1024)
        // gcd(22050, 48000) = 150
        #expect(up.interpolation == 320)
        #expect(up.decimation == 147)

        let down = PolyphaseResampler(inputRate: 48_000, outputRate: 22_050, maxInputFrames: 1024)
        #expect(down.interpolation == 147)
        #expect(down.decimation == 320)

        let same = PolyphaseResampler(inputRate: 48_000, outputRate: 48_000, maxInputFrames: 128)
        #expect(same.interpolation == 1)
        #expect(same.decimation == 1)
    }

    @Test func producesRoughlyTheExpectedSampleCount() {
        let resampler = PolyphaseResampler(inputRate: 22_050, outputRate: 48_000, maxInputFrames: 2048)
        let input = [Float](repeating: 0, count: 2048)
        var output = [Float](repeating: 0, count: 8192)

        let produced = run(resampler, input, &output)
        let expected = 2048.0 * 48_000.0 / 22_050.0
        // Allow a couple of samples of phase slack at the block boundary.
        #expect(abs(Double(produced) - expected) < 3)
    }

    @Test func preservesLevelOfAConstantSignal() {
        // Unity DC gain: a constant must come out at the same value, otherwise
        // resampling would change playback loudness.
        let resampler = PolyphaseResampler(inputRate: 22_050, outputRate: 48_000, maxInputFrames: 1024)
        let input = [Float](repeating: 0.5, count: 1024)
        var output = [Float](repeating: 0, count: 4096)

        // Prime past the filter's startup transient.
        _ = run(resampler, input, &output)
        let produced = run(resampler, input, &output)

        let steady = Array(output[100..<produced])
        let mean = steady.reduce(0, +) / Float(steady.count)
        #expect(abs(mean - 0.5) < 0.01, "DC gain drifted: \(mean)")
    }

    @Test func preservesAToneAtTheCorrectFrequency() {
        // A 300 Hz tone (inside Osho's speech band) must survive upsampling with
        // its frequency and amplitude intact.
        let inputRate = 22_050.0
        let outputRate = 48_000.0
        let resampler = PolyphaseResampler(
            inputRate: Int(inputRate), outputRate: Int(outputRate), maxInputFrames: 4096
        )
        let frequency = 300.0
        let input = (0..<4096).map { Float(0.5 * sin(2 * .pi * frequency * Double($0) / inputRate)) }
        var output = [Float](repeating: 0, count: 12_000)

        _ = run(resampler, input, &output)
        let produced = run(resampler, input, &output)
        let steady = Array(output[200..<(produced - 10)])

        // Amplitude: RMS of a sine is A/sqrt(2).
        let rms = sqrt(steady.reduce(Float(0)) { $0 + $1 * $1 } / Float(steady.count))
        #expect(abs(rms - Float(0.5 / 2.0.squareRoot())) < 0.02, "amplitude changed: \(rms)")

        // Frequency: count zero crossings to estimate the period.
        var crossings = 0
        for index in 1..<steady.count where steady[index - 1] < 0 && steady[index] >= 0 {
            crossings += 1
        }
        let seconds = Double(steady.count) / outputRate
        let measured = Double(crossings) / seconds
        #expect(abs(measured - frequency) < 6, "frequency shifted to \(measured) Hz")
    }

    @Test func suppressesContentAboveTheOutputNyquist() {
        // Downsampling 48k -> 22.05k must attenuate an 18 kHz tone rather than
        // alias it back into the speech band.
        let resampler = PolyphaseResampler(inputRate: 48_000, outputRate: 22_050, maxInputFrames: 4096)
        let input = (0..<4096).map { Float(0.5 * sin(2 * .pi * 18_000 * Double($0) / 48_000)) }
        var output = [Float](repeating: 0, count: 4096)

        _ = run(resampler, input, &output)
        let produced = run(resampler, input, &output)
        let steady = Array(output[100..<produced])
        let rms = sqrt(steady.reduce(Float(0)) { $0 + $1 * $1 } / Float(steady.count))
        // Should be far below the 0.354 RMS of the unfiltered tone.
        #expect(rms < 0.05, "aliasing leaked through at \(rms)")
    }

    @Test func roundTripThroughTheModelRateStaysRecognisable() {
        // The real chain: 22.05k -> 48k -> 22.05k. Speech-band content must come
        // back essentially unchanged, since this wraps every processed frame.
        let up = PolyphaseResampler(inputRate: 22_050, outputRate: 48_000, maxInputFrames: 4096)
        let down = PolyphaseResampler(inputRate: 48_000, outputRate: 22_050, maxInputFrames: 12_000)

        let input = (0..<4096).map { index -> Float in
            let t = Double(index) / 22_050.0
            return Float(0.3 * sin(2 * .pi * 220 * t) + 0.15 * sin(2 * .pi * 700 * t))
        }
        var mid = [Float](repeating: 0, count: 12_000)
        var out = [Float](repeating: 0, count: 12_000)

        // Two passes so measurements avoid the startup transient.
        for _ in 0..<2 {
            let m = run(up, input, &mid)
            _ = down.process(input: mid, count: m, output: &out, outputCapacity: out.count)
        }
        let midCount = run(up, input, &mid)
        let produced = down.process(
            input: mid, count: midCount, output: &out, outputCapacity: out.count
        )

        let inRms = sqrt(input.reduce(Float(0)) { $0 + $1 * $1 } / Float(input.count))
        let steady = Array(out[100..<(produced - 10)])
        let outRms = sqrt(steady.reduce(Float(0)) { $0 + $1 * $1 } / Float(steady.count))
        #expect(abs(20 * log10(outRms / inRms)) < 0.5, "round trip changed level by \(20 * log10(outRms / inRms)) dB")
    }

    @Test func passesThroughUnchangedWhenRatesMatch() {
        let resampler = PolyphaseResampler(inputRate: 48_000, outputRate: 48_000, maxInputFrames: 512)
        let input = (0..<512).map { Float(sin(Double($0) * 0.05)) * 0.4 }
        var output = [Float](repeating: 0, count: 1024)
        _ = run(resampler, input, &output)
        let produced = run(resampler, input, &output)
        #expect(produced == 512)
        // 1:1 still runs through the filter, so allow a small group-delay shift
        // but require the energy to be preserved.
        let inRms = sqrt(input.reduce(Float(0)) { $0 + $1 * $1 } / Float(input.count))
        let outRms = sqrt(output[0..<produced].reduce(Float(0)) { $0 + $1 * $1 } / Float(produced))
        #expect(abs(20 * log10(outRms / inRms)) < 1.0)
    }

    @Test func resetClearsFilterMemory() {
        let resampler = PolyphaseResampler(inputRate: 22_050, outputRate: 48_000, maxInputFrames: 512)
        let loud = [Float](repeating: 0.9, count: 512)
        var output = [Float](repeating: 0, count: 2048)
        _ = run(resampler, loud, &output)

        resampler.reset()
        let silence = [Float](repeating: 0, count: 512)
        let produced = run(resampler, silence, &output)
        // With history cleared, silence in must give silence out.
        #expect(output[0..<produced].allSatisfy { abs($0) < 1e-6 })
    }

    @Test func neverExceedsTheReportedOutputBound() {
        let resampler = PolyphaseResampler(inputRate: 22_050, outputRate: 48_000, maxInputFrames: 1024)
        let bound = resampler.maximumOutputCount(forInputCount: 1024)
        var output = [Float](repeating: 0, count: bound)
        let input = [Float](repeating: 0.1, count: 1024)
        // Repeated calls accumulate phase; none may overrun the bound.
        for _ in 0..<20 {
            let produced = resampler.process(
                input: input, count: input.count, output: &output, outputCapacity: bound
            )
            #expect(produced <= bound)
        }
    }

    // MARK: - Helpers

    private func run(
        _ resampler: PolyphaseResampler,
        _ input: [Float],
        _ output: inout [Float]
    ) -> Int {
        let capacity = output.count
        return resampler.process(
            input: input, count: input.count, output: &output, outputCapacity: capacity
        )
    }
}
