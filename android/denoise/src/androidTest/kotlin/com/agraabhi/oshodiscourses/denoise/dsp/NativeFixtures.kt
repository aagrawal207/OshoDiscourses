package com.agraabhi.oshodiscourses.denoise.dsp

import androidx.test.platform.app.InstrumentationRegistry
import com.agraabhi.oshodiscourses.core.domain.player.DeepFilterStatus
import com.agraabhi.oshodiscourses.core.model.NoiseReductionMode
import com.agraabhi.oshodiscourses.core.model.VoiceFocusPreset
import com.agraabhi.oshodiscourses.denoise.AssetDeepFilterModel
import org.junit.Assert.fail

/** The real bundled model and native libraries, as the app ships them. */
object NativeFixtures {
    val modelSource: DeepFilterModelSource by lazy {
        AssetDeepFilterModel(InstrumentationRegistry.getInstrumentation().targetContext)
    }

    val modelPath: String by lazy { checkNotNull(modelSource.modelPath()) { "model asset missing" } }

    fun processor(): NoiseReductionProcessor = NoiseReductionProcessor(DefaultRNNoiseFactory, modelSource)

    fun deepFilter(): DeepFilterProcessor = DeepFilterProcessor(modelSource)

    fun ready(
        mode: NoiseReductionMode,
        channels: Int = 1,
        maxFrames: Int = 1024,
        sampleRate: Double = 22_050.0,
        gain: Float = 1f,
        wetMix: Float = 0.5f,
    ): NoiseReductionProcessor = processor().apply {
        configure(mode, wetMix, 0.7f, 12f, VoiceFocusPreset.FOCUS, outputGain = gain)
        prepare(channels, maxFrames, sampleRate)
        if (mode == NoiseReductionMode.DEEP_FILTER_NET) waitForActive(deepFilter)
    }

    fun waitForActive(processor: DeepFilterProcessor, timeoutMillis: Long = 30_000) {
        val deadline = System.currentTimeMillis() + timeoutMillis
        while (System.currentTimeMillis() < deadline) {
            when (val status = processor.currentStatus) {
                DeepFilterStatus.Active -> return
                DeepFilterStatus.Loading, DeepFilterStatus.Idle -> Thread.sleep(20)
                else -> fail("DeepFilterNet failed to load: ${status.label}")
            }
        }
        fail("DeepFilterNet did not become active within $timeoutMillis ms")
    }

    fun process(processor: DeepFilterProcessor, samples: FloatArray, channel: Int = 0): Boolean =
        processor.process(samples, 0, samples.size, channel)
}
