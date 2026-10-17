package com.agraabhi.oshodiscourses.denoise.dsp

import com.agraabhi.oshodiscourses.denoise.nativebridge.NativeDenoisers
import com.agraabhi.oshodiscourses.denoise.nativebridge.RNNoiseNative

/**
 * RNNoise at 48 kHz (iOS `RNNoiseProcessor`). The model lags two hops (analysis plus lookahead),
 * so the dry mix is delayed two hops at the same rate. Not thread-safe; [close] frees it.
 */
class RNNoiseProcessor private constructor(
    private var handle: Long,
    sourceRate: Double,
    maxFrames: Int,
) : AutoCloseable {
    private val hopSize = RNNoiseNative.frameSize()
    private val stream = DenoiserStream(sourceRate, maxFrames, hopSize)
    private val frameInput = FloatArray(hopSize)
    private val frameOutput = FloatArray(hopSize)
    private val dryHistory = FloatArray(hopSize * MODEL_DELAY_HOPS)
    private var dryIndex = 0
    private val limiter = PeakLimiter(48_000.0)
    private var wetMix = 0.5f

    // A field, not a lambda per call, so the audio path never allocates.
    private val transform = HopTransform { input, inputOffset, output ->
        for (index in 0 until hopSize) frameInput[index] = input[inputOffset + index] * 32768f
        if (!RNNoiseNative.processFrame(handle, frameOutput, frameInput)) return@HopTransform false
        val dryOffset = dryIndex * hopSize
        val wet = wetMix
        for (index in 0 until hopSize) {
            val mixed = wet * (frameOutput[index] / 32768f) + (1 - wet) * dryHistory[dryOffset + index]
            // Pitch filtering can overshoot a full-scale archive; leave headroom before resampling.
            output[index] = if (wet > 0f) limiter.process(mixed) else mixed
            dryHistory[dryOffset + index] = input[inputOffset + index]
        }
        dryIndex = (dryIndex + 1) % MODEL_DELAY_HOPS
        true
    }

    fun reset() {
        if (handle != 0L) RNNoiseNative.reset(handle)
        stream.reset()
        dryHistory.fill(0f)
        dryIndex = 0
        limiter.reset()
    }

    fun process(samples: FloatArray, offset: Int, count: Int, wetMix: Float): Boolean {
        if (handle == 0L) return false
        this.wetMix = wetMix
        return stream.process(samples, offset, count, transform)
    }

    override fun close() {
        if (handle != 0L) RNNoiseNative.destroy(handle)
        handle = 0
    }

    companion object {
        const val MODEL_DELAY_HOPS = 2

        /** Null when the native library is missing (JVM tests) or RNNoise cannot allocate. */
        fun create(sourceRate: Double, maxFrames: Int): RNNoiseProcessor? {
            if (!NativeDenoisers.isAvailable) return null
            val handle = RNNoiseNative.create()
            if (handle == 0L) return null
            return RNNoiseProcessor(handle, sourceRate, maxFrames)
        }
    }
}
