package com.agraabhi.oshodiscourses.denoise.dsp

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/** Deterministic PRNG so noise assertions are reproducible (the iOS tests' SplitMix64). */
class SplitMix64(seed: Long) {
    private var state = seed

    fun next(): Long {
        state += -0x61c8864680b583ebL
        var z = state
        z = (z xor (z ushr 30)) * -0x40a7b892e31b1a47L
        z = (z xor (z ushr 27)) * -0x6b2fb644ecceee15L
        return z xor (z ushr 31)
    }

    /** Uniform in [-1, 1). */
    fun nextUniform(): Float = ((next() ushr 11).toDouble() * (1.0 / 9_007_199_254_740_992.0)).toFloat() * 2 - 1
}

object Signals {
    fun rms(samples: FloatArray, from: Int = 0, to: Int = samples.size): Float {
        if (to <= from) return 0f
        var total = 0.0
        for (index in from until to) total += samples[index].toDouble() * samples[index]
        return sqrt(total / (to - from)).toFloat()
    }

    fun peak(samples: FloatArray): Float = samples.maxOfOrNull { abs(it) } ?: 0f

    fun sine(frequency: Double, sampleRate: Double, count: Int, amplitude: Double = 0.5, startIndex: Int = 0): FloatArray =
        FloatArray(count) { index -> (amplitude * sin(2 * PI * frequency * (startIndex + index) / sampleRate)).toFloat() }

    /** Speech-like syllables with speech's crest factor: loud and quiet slots, then pauses. */
    fun speech(seconds: Double, sampleRate: Double): FloatArray {
        val pitches = doubleArrayOf(150.0, 232.0, 191.0, 305.0, 168.0, 264.0, 212.0)
        val amplitudes = doubleArrayOf(0.99, 0.20, 0.50, 0.12, 0.60, 0.15, 0.35)
        var phase = 0.0
        return FloatArray((seconds * sampleRate).toInt()) { index ->
            val t = index / sampleRate
            val slot = (t / 0.6).toInt()
            val within = t - slot * 0.6
            if (within >= 0.25) {
                phase = 0.0
                0f
            } else {
                phase += 2 * PI * pitches[slot % pitches.size] / sampleRate
                val envelope = min(min(within / 0.02, (0.25 - within) / 0.02), 1.0)
                (amplitudes[slot % amplitudes.size] * max(envelope, 0.0) * sin(phase)).toFloat()
            }
        }
    }

    /** Pitch changes each syllable, so the signal has a single unambiguous alignment. */
    fun syllables(seconds: Double, sampleRate: Double): FloatArray {
        val pitches = doubleArrayOf(150.0, 232.0, 191.0, 305.0, 168.0, 264.0, 212.0, 143.0, 287.0, 176.0)
        val syllable = 0.5
        var phase = 0.0
        return FloatArray((seconds * sampleRate).toInt()) { index ->
            val t = index / sampleRate
            val slot = (t / syllable).toInt()
            val within = t - slot * syllable
            if (within >= 0.35) {
                phase = 0.0
                0f
            } else {
                phase += 2 * PI * pitches[slot % pitches.size] / sampleRate
                val envelope = min(min(within / 0.03, (0.35 - within) / 0.03), 1.0)
                (0.25 * max(envelope, 0.0) * (sin(phase) + 0.5 * sin(2 * phase))).toFloat()
            }
        }
    }

    /** Lag in samples that best aligns [rendered] with [reference]. */
    fun bestLag(reference: FloatArray, rendered: FloatArray, maxLag: Int): Int {
        var bestLag = 0
        var bestScore = 0.0
        val window = min(reference.size, rendered.size) - maxLag - 1
        if (window <= 1000) return 0
        for (lag in 0 until maxLag) {
            var score = 0.0
            var index = 0
            while (index < window) {
                score += reference[index].toDouble() * rendered[index + lag]
                index += 2
            }
            if (score > bestScore) {
                bestScore = score
                bestLag = lag
            }
        }
        return bestLag
    }

    fun maxDifference(left: FloatArray, right: FloatArray): Float {
        var worst = 0f
        for (index in 0 until min(left.size, right.size)) worst = max(worst, abs(left[index] - right[index]))
        return worst
    }
}

/** Mono and multi-channel helpers over the stream's `AudioBufferList`-shaped arguments. */
object Buffers {
    val MONO = intArrayOf(1)

    /** Processes [samples] in place as one mono buffer. */
    fun processMono(processor: NoiseReductionProcessor, samples: FloatArray, frameCount: Int = samples.size): Boolean =
        processor.process(arrayOf(samples), MONO, frameCount)

    /** Renders [signal] through [processor] in mono blocks of [block] frames. */
    fun render(processor: NoiseReductionProcessor, signal: FloatArray, block: Int = 4096): FloatArray {
        val output = FloatArray(signal.size)
        var offset = 0
        while (offset < signal.size) {
            val count = min(block, signal.size - offset)
            val chunk = signal.copyOfRange(offset, offset + count)
            processMono(processor, chunk)
            chunk.copyInto(output, offset)
            offset += count
        }
        return output
    }

    /** A planar or interleaved block, like `AVAudioPCMBuffer`. */
    class Block(val channels: Int, val frames: Int, val interleaved: Boolean) {
        val buffers: Array<FloatArray> =
            if (interleaved) arrayOf(FloatArray(frames * channels)) else Array(channels) { FloatArray(frames) }
        val lanes: IntArray = if (interleaved) intArrayOf(channels) else IntArray(channels) { 1 }

        fun fill(offset: Int = 0, silent: Boolean = false) {
            for (channel in 0 until channels) {
                for (frame in 0 until frames) {
                    val value = if (silent) {
                        0f
                    } else {
                        ((if (channel == 0) 0.7 else 0.4) * sin((offset + frame) * (if (channel == 0) 0.071 else 0.107))).toFloat()
                    }
                    set(channel, frame, value)
                }
            }
        }

        operator fun set(channel: Int, frame: Int, value: Float) {
            if (interleaved) buffers[0][frame * channels + channel] = value else buffers[channel][frame] = value
        }

        operator fun get(channel: Int, frame: Int): Float =
            if (interleaved) buffers[0][frame * channels + channel] else buffers[channel][frame]

        fun contents(): FloatArray = if (interleaved) buffers[0].copyOf() else buffers.fold(FloatArray(0)) { all, part -> all + part }
    }
}

/** Waits for the deferred discontinuity reset on the maintenance thread. */
fun awaitReset(processor: NoiseReductionProcessor, timeoutMillis: Long = 5_000) {
    awaitCondition(timeoutMillis) { !processor.diagnosticsSnapshot().resetPending }
    check(!processor.diagnosticsSnapshot().resetPending) { "reset did not complete" }
}

fun awaitCondition(timeoutMillis: Long = 10_000, condition: () -> Boolean): Boolean {
    val deadline = System.currentTimeMillis() + timeoutMillis
    while (!condition()) {
        if (System.currentTimeMillis() >= deadline) return false
        Thread.sleep(5)
    }
    return true
}
