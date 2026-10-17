package com.agraabhi.oshodiscourses.denoise.dsp

import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.max

/**
 * No-look-ahead ceiling (iOS `PeakLimiter`): gain never exceeds `ceiling / |sample|`, and the
 * slow release rides over syllables. It is what turns boost into loudness on full-scale audio.
 */
class PeakLimiter(
    sampleRate: Double,
    private val ceiling: Float = DEFAULT_CEILING,
    releaseSeconds: Double = 0.12,
) {
    private val releaseCoefficient = exp(-1 / (max(releaseSeconds, 0.001) * sampleRate)).toFloat()

    /** Current gain reduction; 1 means the limiter is not acting. */
    var gain: Float = 1f
        private set

    fun reset() {
        gain = 1f
    }

    fun process(sample: Float): Float {
        val magnitude = abs(sample)
        val required = if (magnitude > ceiling) ceiling / magnitude else 1f
        gain = if (required < gain) required else required + releaseCoefficient * (gain - required)
        return sample * gain
    }

    companion object {
        /** -1 dBFS leaves room for intersample peaks a later resampler reconstructs. */
        const val DEFAULT_CEILING: Float = 0.891f

        /** -0.3 dBFS for the last stage, where nothing downstream resamples. */
        const val OUTPUT_CEILING: Float = 0.966f
    }
}
