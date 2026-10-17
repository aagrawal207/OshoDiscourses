package com.agraabhi.oshodiscourses.denoise.dsp

import kotlin.math.ceil
import kotlin.math.roundToInt

/** One fixed model hop: reads `hopSize` samples at [inputOffset], writes `hopSize` to [output]. */
fun interface HopTransform {
    fun transform(input: FloatArray, inputOffset: Int, output: FloatArray): Boolean
}

/**
 * Preallocated rate conversion and fixed-hop buffering shared by the neural models (iOS
 * `DenoiserStream`). The caller owns synchronization and the model's state.
 */
class DenoiserStream(
    val sourceRate: Double,
    val maxFrames: Int,
    val hopSize: Int,
    bufferingHops: Int = 1,
    slackFrames: Int = 0,
) {
    val primeCount: Int

    private val toModel: PolyphaseResampler?
    private val fromModel: PolyphaseResampler?
    private val upBuffer: FloatArray
    private val downBuffer: FloatArray
    private val modelInput: FloatArray
    private var inputCount = 0
    private val modelOutput: FloatArray
    private val output: FloatArray
    private var outputCount = 0

    init {
        require(sourceRate.isFinite() && sourceRate in 8_000.0..192_000.0)
        require(maxFrames > 0 && hopSize > 0 && bufferingHops > 0 && slackFrames >= 0)
        val rate = sourceRate.roundToInt()
        if (rate == MODEL_RATE) {
            toModel = null
            fromModel = null
        } else {
            toModel = PolyphaseResampler(rate, MODEL_RATE, maxFrames)
            fromModel = PolyphaseResampler(MODEL_RATE, rate, hopSize)
        }
        val upCapacity = toModel?.maximumOutputCount(maxFrames) ?: maxFrames
        val downCapacity = fromModel?.maximumOutputCount(hopSize) ?: hopSize
        val hopAtSourceRate = ceil(hopSize * sourceRate / MODEL_RATE).toInt()
        primeCount = bufferingHops * hopAtSourceRate + slackFrames + (if (toModel == null) 0 else 4)
        upBuffer = FloatArray(upCapacity)
        downBuffer = FloatArray(downCapacity)
        modelInput = FloatArray(upCapacity + hopSize)
        modelOutput = FloatArray(hopSize)
        output = FloatArray(primeCount + maxFrames + downCapacity + 16)
        reset()
    }

    fun reset() {
        toModel?.reset()
        fromModel?.reset()
        inputCount = 0
        output.fill(0f, 0, primeCount)
        outputCount = primeCount
    }

    /**
     * Returns false without overwriting [samples] if any stage fails. Model errors require
     * the caller to [reset] before reusing this stream.
     */
    fun process(samples: FloatArray, offset: Int, count: Int, transform: HopTransform): Boolean {
        if (count <= 0 || count > maxFrames) return false
        val produced = if (toModel != null) {
            toModel.process(samples, offset, count, upBuffer, 0, upBuffer.size)
        } else {
            System.arraycopy(samples, offset, upBuffer, 0, count)
            count
        }
        if (inputCount + produced > modelInput.size) return false
        System.arraycopy(upBuffer, 0, modelInput, inputCount, produced)
        inputCount += produced

        var consumed = 0
        while (inputCount - consumed >= hopSize) {
            if (!transform.transform(modelInput, consumed, modelOutput)) return false
            consumed += hopSize
            val emitted = if (fromModel != null) {
                fromModel.process(modelOutput, 0, hopSize, downBuffer, 0, downBuffer.size)
            } else {
                System.arraycopy(modelOutput, 0, downBuffer, 0, hopSize)
                hopSize
            }
            // Dropping a hop would misalign every later callback while still reporting success.
            if (outputCount + emitted > output.size) return false
            System.arraycopy(downBuffer, 0, output, outputCount, emitted)
            outputCount += emitted
        }
        if (consumed > 0) {
            inputCount -= consumed
            if (inputCount > 0) System.arraycopy(modelInput, consumed, modelInput, 0, inputCount)
        }
        if (outputCount < count) return false
        System.arraycopy(output, 0, samples, offset, count)
        outputCount -= count
        if (outputCount > 0) System.arraycopy(output, count, output, 0, outputCount)
        return true
    }

    companion object {
        const val MODEL_RATE = 48_000
    }
}
