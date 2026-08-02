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

    init(inputRate: Int, outputRate: Int, maxInputFrames: Int, tapsPerPhase: Int = 16) {
        self.inputRate = inputRate
        self.outputRate = outputRate
        let divisor = Self.greatestCommonDivisor(inputRate, outputRate)
        self.interpolation = outputRate / divisor
        self.decimation = inputRate / divisor
        self.tapsPerPhase = tapsPerPhase

        historyCount = max(tapsPerPhase - 1, 1)
        scratchCapacity = historyCount + max(maxInputFrames, 1)
        history = .allocate(capacity: historyCount)
        history.initialize(repeating: 0, count: historyCount)
        scratch = .allocate(capacity: scratchCapacity)
        scratch.initialize(repeating: 0, count: scratchCapacity)

        let total = interpolation * tapsPerPhase
        coefficients = .allocate(capacity: total)
        coefficients.initialize(repeating: 0, count: total)
        Self.buildCoefficients(
            into: coefficients,
            interpolation: interpolation,
            tapsPerPhase: tapsPerPhase,
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

        // Lay out history followed by the new block. scratch[i] holds absolute
        // input index (inputPosition - historyCount + i).
        scratch.update(from: history, count: historyCount)
        (scratch + historyCount).update(from: input, count: count)

        let endExclusive = inputPosition + count
        let originOffset = historyCount - inputPosition
        var produced = 0

        while nextBase < endExclusive, produced < outputCapacity {
            let basePosition = nextBase + originOffset
            var accumulator: Float = 0
            let phaseBase = nextPhase * tapsPerPhase
            // y[k] = sum_t h[phase][t] * x[base - t]
            for tap in 0..<tapsPerPhase {
                accumulator += coefficients[phaseBase + tap] * scratch[basePosition - tap]
            }
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
        // Cutoff must sit below the lower of the two Nyquist limits: it removes
        // interpolation images when upsampling and prevents aliasing when
        // decimating. 0.45 leaves a modest transition band.
        let upsampledRate = Double(inputRate * interpolation)
        let cutoffHz = 0.45 * Double(min(inputRate, outputRate))
        let normalizedCutoff = cutoffHz / upsampledRate   // cycles per upsampled sample
        let center = Double(total - 1) / 2

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
            // Blackman window: ~-58 dB sidelobes, enough that imaging stays well
            // below this source material's own noise floor.
            let ratio = Double(index) / Double(total - 1)
            let window = 0.42
                - 0.5 * cos(2 * Double.pi * ratio)
                + 0.08 * cos(4 * Double.pi * ratio)
            prototype[index] = sincValue * window
        }

        // Normalise for unity DC gain: each output sample uses one phase, whose
        // taps must sum to 1.
        let sum = prototype.reduce(0, +)
        let scale = sum.magnitude > 1e-12 ? Double(interpolation) / sum : 1

        // Regroup from prototype index (phase + tap * L) into phase-major order.
        for phase in 0..<interpolation {
            for tap in 0..<tapsPerPhase {
                let prototypeIndex = phase + tap * interpolation
                let value = prototypeIndex < total ? prototype[prototypeIndex] * scale : 0
                destination[phase * tapsPerPhase + tap] = Float(value)
            }
        }
    }

    static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var x = abs(a), y = abs(b)
        while y != 0 { (x, y) = (y, x % y) }
        return max(x, 1)
    }
}
