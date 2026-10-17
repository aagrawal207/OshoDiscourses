package com.agraabhi.oshodiscourses.denoise.dsp

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.agraabhi.oshodiscourses.core.model.NoiseReductionMode
import com.agraabhi.oshodiscourses.core.model.VoiceFocusPreset
import com.google.common.truth.Truth.assertWithMessage
import kotlin.math.log10
import org.junit.Test
import org.junit.runner.RunWith

/** The boost ladder over real RNNoise and DeepFilterNet output (iOS `VolumeBoostTests`). */
@RunWith(AndroidJUnit4::class)
class VolumeBoostNativeTest {
    private fun run(mode: NoiseReductionMode, signal: FloatArray, gain: Float): FloatArray {
        val processor = NativeFixtures.processor()
        processor.configure(mode, 0.5f, 0.7f, 12f, VoiceFocusPreset.FOCUS, outputGain = gain)
        processor.prepare(1, 4096, 22_050.0)
        if (mode == NoiseReductionMode.DEEP_FILTER_NET) NativeFixtures.waitForActive(processor.deepFilter)
        return Buffers.render(processor, signal)
    }

    @Test
    fun boostGetsLouderWithoutEverClipping() {
        val signal = Signals.speech(4.0, 22_050.0)
        for (mode in listOf(NoiseReductionMode.RNNOISE, NoiseReductionMode.DEEP_FILTER_NET)) {
            val reference = Signals.rms(run(mode, signal, 1f))
            var last = reference
            for (gain in floatArrayOf(1.5f, 2f, 3f, 4f)) {
                val boosted = run(mode, signal, gain)
                assertWithMessage("$mode $gain x clipped").that(Signals.peak(boosted)).isAtMost(1f)
                val level = Signals.rms(boosted)
                assertWithMessage("$mode $gain x not louder").that(level).isGreaterThan(last)
                last = level
            }
            if (mode == NoiseReductionMode.RNNOISE) {
                val gainDb = 20 * log10(Signals.rms(run(mode, signal, 4f)) / reference)
                assertWithMessage("4x achieved only $gainDb dB").that(gainDb).isGreaterThan(3f)
            }
        }
    }
}
