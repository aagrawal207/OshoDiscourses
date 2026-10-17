package com.agraabhi.oshodiscourses.denoise

import android.os.Bundle
import android.util.Log
import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.AudioProcessor.AudioFormat
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.agraabhi.oshodiscourses.core.domain.player.AudioProcessingStatus
import com.agraabhi.oshodiscourses.core.domain.settings.UserSettings
import com.agraabhi.oshodiscourses.core.model.NoiseReductionMode
import com.agraabhi.oshodiscourses.core.testing.FakeSettingsRepository
import com.agraabhi.oshodiscourses.denoise.dsp.NativeFixtures
import com.agraabhi.oshodiscourses.denoise.dsp.Signals
import com.agraabhi.oshodiscourses.denoise.dsp.SplitMix64
import com.agraabhi.oshodiscourses.denoise.dsp.awaitCondition
import com.google.common.truth.Truth.assertThat
import com.google.common.truth.Truth.assertWithMessage
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith

/** The Media3 processor over the real models, plus the Best Quality real-time-factor benchmark. */
@RunWith(AndroidJUnit4::class)
class DenoiseChainNativeTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    @After
    fun tearDown() = scope.cancel()

    private fun engine(mode: NoiseReductionMode, boost: Double = 2.0) = DenoiseEngine(
        FakeSettingsRepository(UserSettings(noiseReduction = true, noiseReductionMode = mode, volumeBoost = boost)),
        NativeFixtures.modelSource,
        scope,
    ).apply { onPlaybackChanged(hasTrack = true, isPlaying = true) }

    private fun stereoSpeech(seconds: Double, rate: Int): ShortArray {
        val voice = Signals.syllables(seconds, rate.toDouble())
        val noise = SplitMix64(11)
        return ShortArray(voice.size * 2) { index ->
            val sample = voice[index / 2] * (if (index % 2 == 0) 1f else 0.9f) + noise.nextUniform() * 0.02f
            (sample * 32767).toInt().coerceIn(-32768, 32767).toShort()
        }
    }

    private fun AudioProcessor.feed(samples: ShortArray, from: Int, frames: Int, channels: Int): ByteBuffer {
        val buffer = ByteBuffer.allocateDirect(frames * channels * 2).order(ByteOrder.nativeOrder())
        for (index in 0 until frames * channels) buffer.putShort(samples[from * channels + index])
        buffer.flip()
        queueInput(buffer)
        return getOutput()
    }

    private fun startChain(engine: DenoiseEngine, rate: Int, channels: Int): AudioProcessor {
        val processor = engine.createAudioProcessors().single()
        processor.configure(AudioFormat(rate, channels, C.ENCODING_PCM_16BIT))
        processor.flush(AudioProcessor.StreamMetadata.DEFAULT)
        assertWithMessage("model never became ready").that(
            awaitCondition(30_000) {
                engine.refresh()
                engine.status.value == AudioProcessingStatus.ModelReady || engine.status.value.isActive
            },
        ).isTrue()
        return processor
    }

    @Test
    fun everyModeReachesActiveThroughMedia3() {
        for (mode in NoiseReductionMode.entries) {
            val engine = engine(mode)
            val processor = engine.createAudioProcessors().single()
            processor.configure(AudioFormat(22_050, 2, C.ENCODING_PCM_16BIT))
            processor.flush(AudioProcessor.StreamMetadata.DEFAULT)
            if (mode == NoiseReductionMode.DEEP_FILTER_NET) NativeFixtures.waitForActive(engine.deepFilter)
            val samples = stereoSpeech(2.0, 22_050)
            var frame = 0
            while (frame + 2048 <= samples.size / 2) {
                val output = processor.feed(samples, frame, 2048, 2)
                assertThat(output.remaining()).isEqualTo(2048 * 4)
                frame += 2048
            }
            engine.refresh()
            assertWithMessage("$mode").that(engine.status.value).isEqualTo(AudioProcessingStatus.Active)
            assertWithMessage("$mode").that(engine.state.value.isBoostAvailable).isTrue()
        }
    }

    @Test
    fun liveChoicesKeepProcessingWithoutAnotherChain() = runBlocking {
        val engine = engine(NoiseReductionMode.DEEP_FILTER_NET)
        val processor = startChain(engine, 44_100, 2)
        val samples = stereoSpeech(4.0, 44_100)
        var frame = 0
        var step = 0
        while (frame + 4096 <= samples.size / 2) {
            when (step++) {
                5 -> engine.setStrength(com.agraabhi.oshodiscourses.core.model.DenoiseStrength.STRONG)
                10 -> engine.setVoiceFocus(com.agraabhi.oshodiscourses.core.model.VoiceFocusPreset.STRONG)
                15 -> engine.setBoost(4f)
            }
            processor.feed(samples, frame, 4096, 2)
            engine.refresh()
            if (step > 1) assertWithMessage("step $step").that(engine.status.value).isEqualTo(AudioProcessingStatus.Active)
            frame += 4096
        }
    }

    @Test
    fun bestQualityRunsFasterThanRealTimeOnSixtySecondsOf44kStereo() {
        val rate = 44_100
        val seconds = 60
        val engine = engine(NoiseReductionMode.DEEP_FILTER_NET)
        val processor = startChain(engine, rate, 2)
        val samples = stereoSpeech(seconds.toDouble(), rate)
        val frames = samples.size / 2
        val block = 4096
        val buffer = ByteBuffer.allocateDirect(block * 4).order(ByteOrder.nativeOrder())
        var worstBlockNanos = 0L
        val started = System.nanoTime()
        var frame = 0
        while (frame < frames) {
            val count = minOf(block, frames - frame)
            buffer.clear()
            for (index in 0 until count * 2) buffer.putShort(samples[frame * 2 + index])
            buffer.flip()
            val blockStart = System.nanoTime()
            processor.queueInput(buffer)
            processor.getOutput()
            worstBlockNanos = maxOf(worstBlockNanos, System.nanoTime() - blockStart)
            frame += count
        }
        val elapsedSeconds = (System.nanoTime() - started) / 1e9
        val realTimeFactor = elapsedSeconds / seconds
        engine.refresh()
        val report = "Best Quality, 44.1 kHz stereo, 60 s: real-time factor %.3f (%.1fx faster than real time), worst %d-frame block %.2f ms of %.2f ms"
            .format(realTimeFactor, 1 / realTimeFactor, block, worstBlockNanos / 1e6, block * 1000.0 / rate)
        Log.i("DenoiseBenchmark", report)
        InstrumentationRegistry.getInstrumentation().sendStatus(0, Bundle().apply { putString("stream", report + "\n") })
        assertThat(engine.status.value).isEqualTo(AudioProcessingStatus.Active)
        assertWithMessage(report).that(realTimeFactor).isLessThan(1.0)
    }
}
