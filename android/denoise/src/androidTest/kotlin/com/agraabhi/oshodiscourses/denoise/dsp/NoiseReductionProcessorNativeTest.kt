package com.agraabhi.oshodiscourses.denoise.dsp

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.agraabhi.oshodiscourses.core.model.NoiseReductionMode
import com.agraabhi.oshodiscourses.core.model.VoiceFocusPreset
import com.google.common.truth.Truth.assertThat
import com.google.common.truth.Truth.assertWithMessage
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import org.junit.Test
import org.junit.runner.RunWith

/** RNNoise alignment and PCM layouts (iOS `NoiseReductionProcessorTests`). */
@RunWith(AndroidJUnit4::class)
class NoiseReductionProcessorNativeTest {
    private fun rnnoise(wet: Float, maxFrames: Int, rate: Double, channels: Int = 1) = NativeFixtures.processor().apply {
        configure(NoiseReductionMode.RNNOISE, wet, 1f, 12f, VoiceFocusPreset.FOCUS)
        prepare(channels, maxFrames, rate)
    }

    @Test
    fun rnnoiseDrySignalUsesMatchingDelayedFrame() {
        val processor = rnnoise(wet = 0f, maxFrames = 480, rate = 48_000.0)
        val blocks = Array(4) { FloatArray(480) }
        blocks[0][0] = 1f
        for (block in blocks) assertThat(Buffers.processMono(processor, block)).isTrue()
        assertThat(blocks[0].all { abs(it) < 0.0001f }).isTrue()
        assertThat(blocks[1].all { abs(it) < 0.0001f }).isTrue()
        assertThat(blocks[2].all { abs(it) < 0.0001f }).isTrue()
        assertThat(abs(blocks[3][0] - 1)).isLessThan(0.0001f)
    }

    @Test
    fun rnnoiseWetAndDryHaveTheSameMeasuredDelay() {
        val count = 48_000
        var state = 17L
        val signal = FloatArray(count) {
            state = state * 6364136223846793005L + 1
            (((state ushr 32).toDouble() / 4_294_967_295.0) - 0.5).toFloat() * 0.3f
        }
        fun render(wet: Float) = Buffers.render(rnnoise(wet, 1024, 48_000.0), signal, 1024)
        fun lag(output: FloatArray): Int {
            var best = Double.NEGATIVE_INFINITY
            var result = 0
            for (delay in 0 until 2000) {
                var dot = 0.0
                var index = 0
                while (index < count - 2000) {
                    dot += signal[index].toDouble() * output[index + delay]
                    index += 7
                }
                if (dot > best) {
                    best = dot
                    result = delay
                }
            }
            return result
        }
        val dryLag = lag(render(0f))
        val wetLag = lag(render(1f))
        assertWithMessage("one buffered hop plus the model's two-hop lookahead").that(wetLag).isEqualTo(1440)
        assertWithMessage("misaligned blending comb-filters speech").that(dryLag).isEqualTo(wetLag)
    }

    @Test
    fun rnnoiseInterleavedStereoMatchesPlanarProcessing() {
        val planarProcessor = rnnoise(0.5f, 4096, 22_050.0, channels = 2)
        val interleavedProcessor = rnnoise(0.5f, 4096, 22_050.0, channels = 2)
        val planar = Buffers.Block(2, 4096, interleaved = false)
        val interleaved = Buffers.Block(2, 4096, interleaved = true)
        for (pass in 0 until 4) {
            for (frame in 0 until 4096) {
                val t = (pass * 4096 + frame) / 22_050.0
                val left = (0.25 * sin(2 * PI * 237 * t)).toFloat()
                val right = (0.15 * sin(2 * PI * 419 * t)).toFloat()
                planar[0, frame] = left
                planar[1, frame] = right
                interleaved[0, frame] = left
                interleaved[1, frame] = right
            }
            planarProcessor.process(planar.buffers, planar.lanes, 4096)
            interleavedProcessor.process(interleaved.buffers, interleaved.lanes, 4096)
            var error = 0f
            for (lane in 0 until 2) for (frame in 0 until 4096) error = max(error, abs(interleaved[lane, frame] - planar[lane, frame]))
            assertThat(error).isLessThan(0.00001f)
        }
    }

    @Test
    fun rnnoiseNeverClipsAFullScaleRecording() {
        for (sampleRate in doubleArrayOf(22_050.0, 32_000.0, 44_100.0, 48_000.0)) {
            val processor = rnnoise(0.5f, 1024, sampleRate)
            for (pass in 0 until 100) {
                val samples = FloatArray(1024) { index ->
                    val t = (pass * 1024 + index) / sampleRate
                    max(-1.0, min(1.0, sin(2 * PI * 237 * t) + 0.5 * sin(2 * PI * 474 * t))).toFloat()
                }
                Buffers.processMono(processor, samples)
                assertWithMessage("$sampleRate Hz").that(samples.all { it.isFinite() && abs(it) <= 1f }).isTrue()
            }
        }
    }
}
