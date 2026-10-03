import Foundation

/// Preallocated rate conversion and fixed-hop buffering shared by the neural models.
/// The caller owns synchronization and the model's state.
final class DenoiserStream {
    let sourceRate: Double
    let maxFrames: Int
    let hopSize: Int
    let primeCount: Int

    private let toModel: PolyphaseResampler?
    private let fromModel: PolyphaseResampler?
    private let upBuffer: UnsafeMutablePointer<Float>
    private let upCapacity: Int
    private let downBuffer: UnsafeMutablePointer<Float>
    private let downCapacity: Int
    private let modelInput: UnsafeMutablePointer<Float>
    private let inputCapacity: Int
    private var inputCount = 0
    private let modelOutput: UnsafeMutablePointer<Float>
    private let output: UnsafeMutablePointer<Float>
    private let outputCapacity: Int
    private var outputCount = 0

    init(sourceRate: Double, maxFrames: Int, hopSize: Int, bufferingHops: Int = 1, slackFrames: Int = 0) {
        precondition(sourceRate.isFinite && sourceRate >= 8_000 && sourceRate <= 192_000)
        precondition(maxFrames > 0 && hopSize > 0 && bufferingHops > 0 && slackFrames >= 0)
        self.sourceRate = sourceRate
        self.maxFrames = maxFrames
        self.hopSize = hopSize
        let rate = Int(sourceRate.rounded())
        if rate == 48_000 {
            toModel = nil
            fromModel = nil
        } else {
            toModel = PolyphaseResampler(inputRate: rate, outputRate: 48_000, maxInputFrames: maxFrames)
            fromModel = PolyphaseResampler(inputRate: 48_000, outputRate: rate, maxInputFrames: hopSize)
        }
        upCapacity = toModel?.maximumOutputCount(forInputCount: maxFrames) ?? maxFrames
        downCapacity = fromModel?.maximumOutputCount(forInputCount: hopSize) ?? hopSize
        inputCapacity = upCapacity + hopSize
        let hopAtSourceRate = Int(ceil(Double(hopSize) * sourceRate / 48_000))
        primeCount = bufferingHops * hopAtSourceRate + slackFrames + (toModel == nil ? 0 : 4)
        outputCapacity = primeCount + maxFrames + downCapacity + 16
        upBuffer = .allocate(capacity: upCapacity)
        downBuffer = .allocate(capacity: downCapacity)
        modelInput = .allocate(capacity: inputCapacity)
        modelOutput = .allocate(capacity: hopSize)
        output = .allocate(capacity: outputCapacity)
        upBuffer.initialize(repeating: 0, count: upCapacity)
        downBuffer.initialize(repeating: 0, count: downCapacity)
        modelInput.initialize(repeating: 0, count: inputCapacity)
        modelOutput.initialize(repeating: 0, count: hopSize)
        output.initialize(repeating: 0, count: outputCapacity)
        reset()
    }

    deinit {
        upBuffer.deallocate()
        downBuffer.deallocate()
        modelInput.deallocate()
        modelOutput.deallocate()
        output.deallocate()
    }

    func reset() {
        toModel?.reset()
        fromModel?.reset()
        inputCount = 0
        output.update(repeating: 0, count: primeCount)
        outputCount = primeCount
    }

    /// Returns false without overwriting source samples if any stage fails.
    /// Model errors require the caller to reset before reusing this stream.
    func process(
        samples: UnsafeMutablePointer<Float>,
        count: Int,
        transform: (UnsafePointer<Float>, UnsafeMutablePointer<Float>) -> Bool
    ) -> Bool {
        guard count > 0, count <= maxFrames else { return false }
        let produced: Int
        if let toModel {
            produced = toModel.process(input: samples, count: count, output: upBuffer, outputCapacity: upCapacity)
        } else {
            produced = count
            upBuffer.update(from: samples, count: count)
        }
        guard inputCount + produced <= inputCapacity else { return false }
        (modelInput + inputCount).update(from: upBuffer, count: produced)
        inputCount += produced

        var consumed = 0
        while inputCount - consumed >= hopSize {
            guard transform(modelInput + consumed, modelOutput) else { return false }
            consumed += hopSize
            let emitted: Int
            if let fromModel {
                emitted = fromModel.process(input: modelOutput, count: hopSize, output: downBuffer, outputCapacity: downCapacity)
            } else {
                emitted = hopSize
                downBuffer.update(from: modelOutput, count: hopSize)
            }
            // Dropping a full output hop would corrupt every subsequent callback's
            // alignment while still reporting that denoising is active.
            guard outputCount + emitted <= outputCapacity else { return false }
            (output + outputCount).update(from: downBuffer, count: emitted)
            outputCount += emitted
        }
        if consumed > 0 {
            inputCount -= consumed
            if inputCount > 0 {
                memmove(modelInput, modelInput + consumed, inputCount * MemoryLayout<Float>.size)
            }
        }
        guard outputCount >= count else { return false }
        samples.update(from: output, count: count)
        outputCount -= count
        if outputCount > 0 {
            memmove(output, output + count, outputCount * MemoryLayout<Float>.size)
        }
        return true
    }
}
