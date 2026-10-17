package com.agraabhi.oshodiscourses.denoise.nativebridge

import com.agraabhi.oshodiscourses.denoise.dsp.DspLog

/** Loads the JNI shim once. JVM unit tests have no native code and see `false`. */
internal object NativeDenoisers {
    val isAvailable: Boolean by lazy {
        try {
            // Loaded first so the shim's NEEDED entry resolves on every API level.
            System.loadLibrary("deepfilter_bridge")
            System.loadLibrary("osho_denoise")
            DspLog.info("Native", "Loaded RNNoise and DeepFilterNet libraries")
            true
        } catch (error: UnsatisfiedLinkError) {
            DspLog.error("Native", "Native denoisers unavailable: ${error.message}")
            false
        }
    }
}

/** Vendored RNNoise (`OshoDiscourses/RNNoise`). Frames are int16-scaled floats. */
object RNNoiseNative {
    @JvmStatic external fun frameSize(): Int

    @JvmStatic external fun create(): Long

    @JvmStatic external fun reset(handle: Long): Int

    @JvmStatic external fun destroy(handle: Long)

    /** [output] and [input] hold at least [frameSize] samples. */
    @JvmStatic external fun processFrame(handle: Long, output: FloatArray, input: FloatArray): Boolean
}

/**
 * The panic-safe DeepFilterNet bridge (`native/deepfilter-bridge/include/DeepFilterBridge.h`).
 * A handle must never be used from two threads at once.
 */
object DeepFilterNative {
    const val OK = 0
    const val ERR_NULL = -1
    const val ERR_ARG = -2
    const val ERR_PANIC = -3
    const val ERR_RUNTIME = -4

    /** Returns 0 on failure. [attenuationLimitDb] >= 100 means unlimited. */
    @JvmStatic external fun create(modelPath: String, attenuationLimitDb: Float): Long

    @JvmStatic external fun hopSize(handle: Long): Int

    @JvmStatic external fun sampleRate(handle: Long): Int

    @JvmStatic external fun setAttenuationLimit(handle: Long, attenuationLimitDb: Float): Int

    @JvmStatic external fun setPostFilterBeta(handle: Long, beta: Float): Int

    /** Upstream's reset re-primes spectra and grows latency; streams flush with silence instead. */
    @JvmStatic external fun reset(handle: Long): Int

    @JvmStatic external fun destroy(handle: Long)

    /** Writes the model's local SNR estimate to `snr[0]` when [snr] is not null. */
    @JvmStatic external fun processFrame(
        handle: Long,
        input: FloatArray?,
        inputOffset: Int,
        output: FloatArray?,
        frameLength: Int,
        snr: FloatArray?,
    ): Int
}
