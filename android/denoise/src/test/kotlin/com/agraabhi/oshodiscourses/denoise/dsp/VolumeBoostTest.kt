package com.agraabhi.oshodiscourses.denoise.dsp

import com.agraabhi.oshodiscourses.core.model.BoostLevel
import com.agraabhi.oshodiscourses.core.model.NoiseReductionMode
import com.agraabhi.oshodiscourses.core.model.VoiceFocusPreset
import com.google.common.truth.Truth.assertThat
import com.google.common.truth.Truth.assertWithMessage
import kotlin.math.log10
import org.junit.Test

/**
 * A boost must get louder and never clip on an archive mastered to full scale. The JVM
 * suite uses Gentle Cleanup; the RNNoise ladder runs in the instrumented suite.
 */
class VolumeBoostTest {
    private fun run(signal: FloatArray, gain: Float, denoise: Boolean, mode: NoiseReductionMode = NoiseReductionMode.CADENCE): FloatArray {
        val processor = NoiseReductionProcessor()
        processor.prepare(1, 4096, 22_050.0)
        processor.configure(mode, 0.5f, 0.7f, 12f, VoiceFocusPreset.FOCUS, denoiseEnabled = denoise, outputGain = gain)
        return Buffers.render(processor, signal)
    }

    @Test
    fun boostGetsLouderWithoutEverClipping() {
        val signal = Signals.speech(4.0, 22_050.0)
        val reference = Signals.rms(run(signal, 1f, denoise = true))
        var last = reference
        for (gain in floatArrayOf(1.5f, 2f, 3f, 4f)) {
            val boosted = run(signal, gain, denoise = true)
            assertWithMessage("$gain x clipped").that(Signals.peak(boosted)).isAtMost(1f)
            val level = Signals.rms(boosted)
            assertWithMessage("$gain x was not louder than the step below").that(level).isGreaterThan(last)
            last = level
        }
        val gainDb = 20 * log10(Signals.rms(run(signal, 4f, denoise = true)) / reference)
        assertWithMessage("4x achieved only $gainDb dB").that(gainDb).isGreaterThan(3f)
    }

    @Test
    fun boostLeavesRawPlaybackUntouched() {
        val signal = Signals.speech(3.0, 22_050.0)
        assertThat(run(signal, 3f, denoise = false).toList()).isEqualTo(signal.toList())
    }

    @Test
    fun deepFilterBypassDoesNotBoostRawPlayback() {
        val signal = Signals.speech(1.0, 4_000.0)
        val block = Buffers.Block(channels = 2, frames = signal.size, interleaved = false)
        for (index in signal.indices) {
            block[0, index] = signal[index]
            block[1, index] = signal[index] * 0.5f
        }
        val processor = NoiseReductionProcessor()
        processor.prepare(2, signal.size, 4_000.0)
        processor.configure(NoiseReductionMode.DEEP_FILTER_NET, 0.5f, 0.7f, 12f, VoiceFocusPreset.FOCUS, outputGain = 3f)
        processor.process(block.buffers, block.lanes, signal.size)
        assertThat(block.buffers[0].toList()).isEqualTo(signal.toList())
        assertThat(block.buffers[1].toList()).isEqualTo(signal.map { it * 0.5f })
    }

    @Test
    fun unityBoostLeavesTheAudioExactlyAlone() {
        val signal = Signals.speech(2.0, 22_050.0)
        assertThat(run(signal, 1f, denoise = false).toList()).isEqualTo(signal.toList())
    }

    @Test
    fun theBoostCeilingIsReachable() {
        assertThat(BoostLevel.MAXIMUM_GAIN).isAtLeast(4f)
        assertThat(BoostLevel.entries.map { it.gain }).containsExactly(1f, 1.5f, 2f, 3f, 4f).inOrder()
    }
}
