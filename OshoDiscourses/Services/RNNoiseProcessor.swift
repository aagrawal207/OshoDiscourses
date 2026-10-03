import Foundation

/// The vendored model has a 10 ms analysis delay plus a 10 ms spectral lookahead.
/// Both sides of its wet/dry mix must share that delay and its 48 kHz clock.
final class RNNoiseProcessor {
    static let modelDelayHops = 2
    private let handle: OpaquePointer?
    private let hopSize = Int(rnnoise_get_frame_size())
    private let stream: DenoiserStream
    private let frameInput: UnsafeMutablePointer<Float>
    private let dryHistory: UnsafeMutablePointer<Float>
    private var dryIndex = 0
    private var limiter = PeakLimiter(sampleRate: 48_000)

    init(sourceRate: Double, maxFrames: Int) {
        handle = rnnoise_create(nil)
        stream = DenoiserStream(sourceRate: sourceRate, maxFrames: maxFrames, hopSize: hopSize)
        frameInput = .allocate(capacity: hopSize)
        dryHistory = .allocate(capacity: hopSize * Self.modelDelayHops)
        frameInput.initialize(repeating: 0, count: hopSize)
        dryHistory.initialize(repeating: 0, count: hopSize * Self.modelDelayHops)
    }

    deinit {
        if let handle { rnnoise_destroy(handle) }
        frameInput.deallocate()
        dryHistory.deallocate()
    }

    func reset() {
        if let handle { _ = rnnoise_init(handle, nil) }
        stream.reset()
        dryHistory.update(repeating: 0, count: hopSize * Self.modelDelayHops)
        dryIndex = 0
        limiter.reset()
    }

    func process(samples: UnsafeMutablePointer<Float>, count: Int, wetMix: Float) -> Bool {
        guard let handle else { return false }
        return stream.process(samples: samples, count: count) { input, output in
            for index in 0..<self.hopSize { self.frameInput[index] = input[index] * 32768 }
            _ = rnnoise_process_frame(handle, output, self.frameInput)
            let dry = self.dryHistory + self.dryIndex * self.hopSize
            for index in 0..<self.hopSize {
                let mixed = wetMix * (output[index] / 32768) + (1 - wetMix) * dry[index]
                // The model's pitch filtering can overshoot a full-scale archive.
                // Leave reconstruction headroom before returning to the source rate.
                output[index] = wetMix > 0 ? self.limiter.process(mixed) : mixed
                dry[index] = input[index]
            }
            self.dryIndex = (self.dryIndex + 1) % Self.modelDelayHops
            return true
        }
    }
}
