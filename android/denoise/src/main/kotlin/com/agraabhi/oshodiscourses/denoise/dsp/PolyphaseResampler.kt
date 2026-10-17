package com.agraabhi.oshodiscourses.denoise.dsp

import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Polyphase Kaiser-windowed sinc resampler (iOS `PolyphaseResampler`): the archive is mostly
 * 22,050 Hz and both models run at 48 kHz. [process] never allocates; DC gain is unity per phase.
 */
class PolyphaseResampler(
    val inputRate: Int,
    val outputRate: Int,
    maxInputFrames: Int,
    tapsPerPhase: Int? = null,
) {
    val interpolation: Int
    val decimation: Int
    private val taps: Int

    /** Grouped by phase and reversed, so each output's dot product reads forwards. */
    private val coefficients: FloatArray
    private val historyCount: Int
    private val history: FloatArray
    private val scratch: FloatArray

    private var inputPosition = 0L
    private var nextBase = 0L
    private var nextPhase = 0

    init {
        require(inputRate > 0 && outputRate > 0 && maxInputFrames > 0)
        // Transition width stays relative to the lower Nyquist limit, even when decimating hard.
        val ratio = max(1.0, inputRate.toDouble() / outputRate)
        taps = tapsPerPhase ?: (ceil(128 * ratio / 2).toInt() * 2)
        require(taps >= 2)
        val divisor = greatestCommonDivisor(inputRate, outputRate)
        interpolation = outputRate / divisor
        decimation = inputRate / divisor
        historyCount = max(taps - 1, 1)
        history = FloatArray(historyCount)
        scratch = FloatArray(historyCount + max(maxInputFrames, 1))
        coefficients = FloatArray(interpolation * taps)
        buildCoefficients(coefficients, interpolation, taps, inputRate, outputRate)
    }

    /** Worst-case output count for [count] input samples. */
    fun maximumOutputCount(count: Int): Int = ((count.toLong() * interpolation) / decimation + 2).toInt()

    fun reset() {
        history.fill(0f)
        inputPosition = 0
        nextBase = 0
        nextPhase = 0
    }

    /**
     * Resamples [count] samples from [input] at [inputOffset] into [output] at [outputOffset].
     * Returns the number written, or 0 without touching history when [outputCapacity] is short.
     */
    fun process(
        input: FloatArray,
        inputOffset: Int,
        count: Int,
        output: FloatArray,
        outputOffset: Int,
        outputCapacity: Int,
    ): Int {
        if (count <= 0 || count + historyCount > scratch.size) return 0
        if (inputRate == outputRate) {
            if (outputCapacity < count) return 0
            System.arraycopy(input, inputOffset, output, outputOffset, count)
            return count
        }

        // Partially consuming input would leave nextBase outside the next block's history.
        val endExclusive = inputPosition + count
        val steps = (endExclusive - nextBase) * interpolation - nextPhase
        val required = max(0L, (steps + decimation - 1) / decimation)
        if (outputCapacity < required) return 0

        // scratch[i] holds absolute input index (inputPosition - historyCount + i).
        System.arraycopy(history, 0, scratch, 0, historyCount)
        System.arraycopy(input, inputOffset, scratch, historyCount, count)

        val originOffset = historyCount - inputPosition
        var produced = 0
        val taps = taps
        val coefficients = coefficients
        val scratch = scratch
        while (nextBase < endExclusive) {
            val start = (nextBase + originOffset).toInt() - taps + 1
            val phaseBase = nextPhase * taps
            var accumulator = 0f
            for (tap in 0 until taps) {
                accumulator += coefficients[phaseBase + tap] * scratch[start + tap]
            }
            output[outputOffset + produced] = accumulator
            produced += 1
            // Incremental base+phase tracking avoids any counter that overflows on long playback.
            nextPhase += decimation
            nextBase += nextPhase / interpolation
            nextPhase %= interpolation
        }

        inputPosition = endExclusive
        System.arraycopy(scratch, count, history, 0, historyCount)
        // Rebase so positions stay small; only differences between them matter.
        nextBase -= inputPosition
        inputPosition = 0
        return produced
    }

    companion object {
        fun greatestCommonDivisor(a: Int, b: Int): Int {
            var x = abs(a)
            var y = abs(b)
            while (y != 0) {
                val t = x % y
                x = y
                y = t
            }
            return max(x, 1)
        }

        private fun buildCoefficients(
            destination: FloatArray,
            interpolation: Int,
            tapsPerPhase: Int,
            inputRate: Int,
            outputRate: Int,
        ) {
            val total = interpolation * tapsPerPhase
            // Passband ends at 95% of the lower Nyquist limit; beta 8.6 targets ~80 dB rejection.
            val upsampledRate = inputRate.toDouble() * interpolation
            val cutoffHz = 0.475 * min(inputRate, outputRate)
            val normalizedCutoff = cutoffHz / upsampledRate
            val center = (total - 1) / 2.0
            val beta = 8.6
            val windowScale = besselI0(beta)

            val prototype = DoubleArray(total)
            for (index in 0 until total) {
                val offset = index - center
                val sincValue = if (abs(offset) < 1e-12) {
                    2 * normalizedCutoff
                } else {
                    sin(2 * Math.PI * normalizedCutoff * offset) / (Math.PI * offset)
                }
                val position = offset / center
                val window = besselI0(beta * sqrt(max(0.0, 1 - position * position))) / windowScale
                prototype[index] = sincValue * window
            }

            for (phase in 0 until interpolation) {
                var phaseSum = 0.0
                for (tap in 0 until tapsPerPhase) phaseSum += prototype[phase + tap * interpolation]
                val scale = if (abs(phaseSum) > 1e-12) 1 / phaseSum else 1.0
                for (tap in 0 until tapsPerPhase) {
                    val prototypeIndex = phase + tap * interpolation
                    val value = if (prototypeIndex < total) prototype[prototypeIndex] * scale else 0.0
                    destination[phase * tapsPerPhase + tapsPerPhase - 1 - tap] = value.toFloat()
                }
            }
        }

        private fun besselI0(value: Double): Double {
            var sum = 1.0
            var term = 1.0
            for (index in 1..40) {
                term *= value * value / (4.0 * index * index)
                sum += term
                if (term < sum * 1e-15) break
            }
            return sum
        }
    }
}
