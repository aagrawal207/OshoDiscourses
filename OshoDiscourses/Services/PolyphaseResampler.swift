import Accelerate
import Foundation

/// Streaming rational-ratio resampler (polyphase windowed-sinc FIR).
///
/// This exists because the discourse archive is not 48 kHz. The Hindi talks are
/// 22,050 Hz mono-ish 43 kbps MP3s, while both RNNoise and DeepFilterNet are
/// 48 kHz models — so without resampling, DeepFilterNet simply cannot run on
/// most of the catalog and audio passes through untouched.
///
/// Design notes:
/// - Upsampling by `L` then keeping every `M`th sample is done in one polyphase
///   step, so the zero-stuffed signal is never materialised. Cost is
///   `tapsPerPhase` multiply-adds per *output* sample regardless of how large L
///   is (L is 320 for 22.05k → 48k).
/// - Nothing is allocated in `process`; all buffers are sized up front from
///   `maxInputFrames`.
/// - Coefficients are normalised for unity DC gain per phase, so a constant
///   input comes out at the same level.
final class PolyphaseResampler: @unchecked Sendable {

    let inputRate: Int
    let outputRate: Int
    /// Interpolation factor (upsampling).
    let interpolation: Int
    /// Decimation factor.
    let decimation: Int
    private let tapsPerPhase: Int

    /// Coefficients grouped by phase: `coefficients[phase * tapsPerPhase + tap]`.
    /// Grouping this way keeps each output sample's taps contiguous.
    private let coefficients: UnsafeMutablePointer<Float>
    /// Trailing input samples carried between calls (the FIR's history).
    private let history: UnsafeMutablePointer<Float>
    private let historyCount: Int
    /// `history` followed by the current input block.
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchCapacity: Int

    /// Absolute index of the next input sample to be fed.
    private var inputPosition = 0
    /// Absolute input index the next output sample is centred on.
    private var nextBase = 0
    /// Sub-sample phase of the next output, in 1/interpolation units.
    private var nextPhase = 0

    init(inputRate: Int, outputRate: Int, maxInputFrames: Int, tapsPerPhase: Int? = nil) {
        precondition(inputRate > 0 && outputRate > 0 && maxInputFrames > 0)
        // Keep the transition width relative to the lower Nyquist limit, including
        // heavily decimated streams. A fixed short FIR aliases those streams.
        let ratio = max(1, Double(inputRate) / Double(outputRate))
        let taps = tapsPerPhase ?? Int(ceil(128 * ratio / 2)) * 2
        precondition(taps >= 2)
        self.inputRate = inputRate
        self.outputRate = outputRate
        let divisor = Self.greatestCommonDivisor(inputRate, outputRate)
        self.interpolation = outputRate / divisor
        self.decimation = inputRate / divisor
        self.tapsPerPhase = taps

        historyCount = max(taps - 1, 1)
        scratchCapacity = historyCount + max(maxInputFrames, 1)
        history = .allocate(capacity: historyCount)
        history.initialize(repeating: 0, count: historyCount)
        scratch = .allocate(capacity: scratchCapacity)
        scratch.initialize(repeating: 0, count: scratchCapacity)

        let total = interpolation * taps
        coefficients = .allocate(capacity: total)
        coefficients.initialize(repeating: 0, count: total)
        Self.buildCoefficients(
            into: coefficients,
            interpolation: interpolation,
            tapsPerPhase: taps,
            inputRate: inputRate,
            outputRate: outputRate
        )
    }

    deinit {
        coefficients.deallocate()
        history.deallocate()
        scratch.deallocate()
    }

    /// Worst-case number of output samples for a given input count, so callers
    /// can size destination buffers without guessing.
    func maximumOutputCount(forInputCount count: Int) -> Int {
        // Each input sample yields at most ceil(L/M) outputs, plus one for a
        // partially advanced phase carried in from the previous call.
        (count * interpolation) / decimation + 2
    }

    /// Reset filter memory and resampling phase (track change or seek).
    func reset() {
        history.update(repeating: 0, count: historyCount)
        inputPosition = 0
        nextBase = 0
        nextPhase = 0
    }

    /// Resample `count` samples, writing to `output`. Returns the number of
    /// samples written, which varies from call to call by design.
    @discardableResult
    func process(
        input: UnsafePointer<Float>,
        count: Int,
        output: UnsafeMutablePointer<Float>,
        outputCapacity: Int
    ) -> Int {
        guard count > 0, count + historyCount <= scratchCapacity else { return 0 }
        if inputRate == outputRate {
            guard outputCapacity >= count else { return 0 }
            output.update(from: input, count: count)
            return count
        }

        // Reject short destinations before advancing history. Partially consuming
        // input would leave nextBase pointing outside the next block's history.
        let endExclusive = inputPosition + count
        let steps = (endExclusive - nextBase) * interpolation - nextPhase
        let required = max(0, (steps + decimation - 1) / decimation)
        guard outputCapacity >= required else { return 0 }

        // Lay out history followed by the new block. scratch[i] holds absolute
        // input index (inputPosition - historyCount + i).
        scratch.update(from: history, count: historyCount)
        (scratch + historyCount).update(from: input, count: count)

        let originOffset = historyCount - inputPosition
        var produced = 0

        while nextBase < endExclusive {
            let basePosition = nextBase + originOffset
            var accumulator: Float = 0
            let phaseBase = nextPhase * tapsPerPhase
            vDSP_dotpr(
                coefficients + phaseBase, 1, scratch + basePosition - tapsPerPhase + 1, 1,
                &accumulator, vDSP_Length(tapsPerPhase)
            )
            output[produced] = accumulator
            produced += 1

            // Advance one output step: the read position moves by `decimation`
            // in units of 1/interpolation input samples. Tracking base+phase
            // incrementally avoids any counter that could overflow on long
            // playback.
            nextPhase += decimation
            nextBase += nextPhase / interpolation
            nextPhase %= interpolation
        }

        inputPosition = endExclusive
        // Carry the final `historyCount` samples for the next call.
        history.update(from: scratch + count, count: historyCount)
        return produced
    }

    // MARK: - Coefficients

    private static func buildCoefficients(
        into destination: UnsafeMutablePointer<Float>,
        interpolation: Int,
        tapsPerPhase: Int,
        inputRate: Int,
        outputRate: Int
    ) {
        let total = interpolation * tapsPerPhase
        // Passband ends at 90% of the lower Nyquist limit; stopband starts at
        // Nyquist. Kaiser beta 8.6 targets roughly 80 dB of image/alias rejection.
        let upsampledRate = Double(inputRate * interpolation)
        let cutoffHz = 0.475 * Double(min(inputRate, outputRate))
        let normalizedCutoff = cutoffHz / upsampledRate   // cycles per upsampled sample
        let center = Double(total - 1) / 2
        let beta = 8.6
        let windowScale = besselI0(beta)

        var prototype = [Double](repeating: 0, count: total)
        for index in 0..<total {
            let offset = Double(index) - center
            // Ideal lowpass impulse response.
            let sincValue: Double
            if abs(offset) < 1e-12 {
                sincValue = 2 * normalizedCutoff
            } else {
                let argument = 2 * Double.pi * normalizedCutoff * offset
                sincValue = sin(argument) / (Double.pi * offset)
            }
            let position = offset / center
            let window = besselI0(beta * sqrt(max(0, 1 - position * position))) / windowScale
            prototype[index] = sincValue * window
        }

        for phase in 0..<interpolation {
            var phaseSum = 0.0
            for tap in 0..<tapsPerPhase {
                phaseSum += prototype[phase + tap * interpolation]
            }
            let scale = abs(phaseSum) > 1e-12 ? 1 / phaseSum : 1
            for tap in 0..<tapsPerPhase {
                let prototypeIndex = phase + tap * interpolation
                let value = prototypeIndex < total ? prototype[prototypeIndex] * scale : 0
                // Reversed taps make both dot-product inputs contiguous forwards.
                destination[phase * tapsPerPhase + tapsPerPhase - 1 - tap] = Float(value)
            }
        }
    }

    private static func besselI0(_ value: Double) -> Double {
        var sum = 1.0
        var term = 1.0
        for index in 1...40 {
            term *= value * value / (4 * Double(index * index))
            sum += term
            if term < sum * 1e-15 { break }
        }
        return sum
    }

    static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var x = abs(a), y = abs(b)
        while y != 0 { (x, y) = (y, x % y) }
        return max(x, 1)
    }
}
