package com.agraabhi.oshodiscourses.denoise

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.AudioProcessor.AudioFormat
import com.agraabhi.oshodiscourses.core.domain.player.AudioMixFailure
import com.agraabhi.oshodiscourses.core.domain.player.AudioProcessingStatus
import com.agraabhi.oshodiscourses.core.domain.player.DeepFilterStatus
import com.agraabhi.oshodiscourses.core.domain.settings.UserSettings
import com.agraabhi.oshodiscourses.core.model.DenoiseStrength
import com.agraabhi.oshodiscourses.core.model.NoiseReductionMode
import com.agraabhi.oshodiscourses.core.model.VoiceFocusPreset
import com.agraabhi.oshodiscourses.core.testing.FakeSettingsRepository
import com.agraabhi.oshodiscourses.denoise.dsp.DeepFilterModelSource
import com.agraabhi.oshodiscourses.denoise.dsp.awaitCondition
import com.agraabhi.oshodiscourses.denoise.media3.NoiseReductionAudioProcessor
import com.google.common.truth.Truth.assertThat
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Test

class DenoiseEngineTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
    private var now = 0L

    @After
    fun tearDown() = scope.cancel()

    private fun engine(settings: FakeSettingsRepository = FakeSettingsRepository()) =
        DenoiseEngine(settings, DeepFilterModelSource { null }, scope, uptimeMillis = { now }, pollIntervalMillis = 60_000)

    private fun AudioProcessor.feed(frames: Int = 1024) {
        val buffer = ByteBuffer.allocateDirect(frames * 2).order(ByteOrder.nativeOrder())
        for (index in 0 until frames) buffer.putShort((kotlin.math.sin(index * 0.05) * 8000).toInt().toShort())
        buffer.flip()
        queueInput(buffer)
        getOutput()
    }

    private fun attach(engine: DenoiseEngine): NoiseReductionAudioProcessor {
        val processor = engine.createAudioProcessors().single() as NoiseReductionAudioProcessor
        processor.configure(AudioFormat(22_050, 1, C.ENCODING_PCM_16BIT))
        processor.flush(AudioProcessor.StreamMetadata.DEFAULT)
        return processor
    }

    @Test
    fun startsFromTheSavedSettings() {
        val settings = FakeSettingsRepository(
            UserSettings(noiseReduction = true, denoiseStrength = DenoiseStrength.STRONG, volumeBoost = 3.0),
        )
        val state = engine(settings).state.value
        assertThat(state.isEnabled).isTrue()
        assertThat(state.strength).isEqualTo(DenoiseStrength.STRONG)
        assertThat(state.boostGain).isEqualTo(3f)
        assertThat(state.mode).isEqualTo(NoiseReductionMode.DEEP_FILTER_NET)
        assertThat(state.voiceFocus).isEqualTo(VoiceFocusPreset.LIFT)
        assertThat(state.status).isEqualTo(AudioProcessingStatus.WaitingForPlayback)
    }

    @Test
    fun offIsOriginalSound() {
        val engine = engine()
        assertThat(engine.state.value.status).isEqualTo(AudioProcessingStatus.Off)
        assertThat(engine.status.value.label).isEqualTo("Original sound")
        assertThat(engine.state.value.isBoostAvailable).isFalse()
    }

    @Test
    fun choicesPersistAndApplyLiveToTheSameChain() = runBlocking {
        val settings = FakeSettingsRepository()
        val engine = engine(settings)
        engine.setEnabled(true)
        engine.setMode(NoiseReductionMode.CADENCE)
        engine.onPlaybackChanged(hasTrack = true, isPlaying = true)
        val processor = attach(engine)
        processor.feed()
        engine.refresh()
        assertThat(engine.status.value).isEqualTo(AudioProcessingStatus.Active)
        assertThat(engine.state.value.isBoostAvailable).isTrue()

        engine.setStrength(DenoiseStrength.LIGHT)
        engine.setVoiceFocus(VoiceFocusPreset.STRONG)
        engine.setBoost(9f)
        processor.feed()
        engine.refresh()
        assertThat(engine.status.value).isEqualTo(AudioProcessingStatus.Active)
        assertThat(engine.state.value.isProcessorAttached).isTrue()
        assertThat(engine.state.value.boostGain).isEqualTo(4f)
        val saved = settings.settings.value
        assertThat(saved.noiseReduction).isTrue()
        assertThat(saved.noiseReductionMode).isEqualTo(NoiseReductionMode.CADENCE)
        assertThat(saved.denoiseStrength).isEqualTo(DenoiseStrength.LIGHT)
        assertThat(saved.voiceFocusPreset).isEqualTo(VoiceFocusPreset.STRONG)
        assertThat(saved.volumeBoost).isEqualTo(4.0)
        assertThat(engine.state.value.accessibilityValue).isEqualTo("On, Gentle Cleanup, Light noise reduction. Enhancement is on")
    }

    @Test
    fun repositoryChangesAreAdopted() {
        val settings = FakeSettingsRepository()
        val engine = engine(settings)
        runBlocking {
            settings.setNoiseReduction(true)
            settings.setVoiceFocusPreset(VoiceFocusPreset.FOCUS)
            settings.setVolumeBoost(0.5)
        }
        val state = engine.state.value
        assertThat(state.isEnabled).isTrue()
        assertThat(state.voiceFocus).isEqualTo(VoiceFocusPreset.FOCUS)
        assertThat(state.boostGain).isEqualTo(1f)
    }

    @Test
    fun statusFollowsPlaybackAndBufferEvidence() = runBlocking {
        val engine = engine()
        engine.setEnabled(true)
        engine.setMode(NoiseReductionMode.CADENCE)
        assertThat(engine.status.value).isEqualTo(AudioProcessingStatus.WaitingForPlayback)
        engine.onPlaybackChanged(hasTrack = true, isPlaying = true)
        assertThat(engine.status.value).isEqualTo(AudioProcessingStatus.Preparing)
        val processor = attach(engine)
        engine.refresh()
        assertThat(engine.status.value).isEqualTo(AudioProcessingStatus.Preparing)
        processor.feed()
        engine.refresh()
        assertThat(engine.status.value).isEqualTo(AudioProcessingStatus.Active)

        now += 1_000
        engine.refresh()
        assertThat(engine.status.value).isEqualTo(AudioProcessingStatus.Active)
        now += 2_500
        engine.refresh()
        assertThat(engine.status.value).isEqualTo(AudioProcessingStatus.WaitingForAudio)
        assertThat(engine.status.value.label).isEqualTo("Enhancement paused")

        engine.onPlaybackChanged(hasTrack = true, isPlaying = false)
        assertThat(engine.status.value).isEqualTo(AudioProcessingStatus.WaitingForPlayback)
        engine.onPlaybackChanged(hasTrack = true, isPlaying = false, failed = true)
        assertThat(engine.status.value).isEqualTo(AudioProcessingStatus.SetupFailed(AudioMixFailure.PLAYBACK))
        assertThat(engine.status.value.label).isEqualTo("Playback unavailable")
    }

    @Test
    fun disablingPassesAudioThroughAndReportsOff() = runBlocking {
        val engine = engine()
        engine.setEnabled(true)
        engine.setMode(NoiseReductionMode.CADENCE)
        engine.onPlaybackChanged(hasTrack = true, isPlaying = true)
        val processor = attach(engine)
        engine.setEnabled(false)
        val buffer = ByteBuffer.allocateDirect(2048).order(ByteOrder.nativeOrder())
        for (index in 0 until 1024) buffer.putShort((index * 13).toShort())
        buffer.flip()
        processor.queueInput(buffer)
        val output = processor.getOutput()
        for (index in 0 until 1024) assertThat(output.getShort(index * 2)).isEqualTo((index * 13).toShort())
        assertThat(engine.status.value).isEqualTo(AudioProcessingStatus.Off)
    }

    @Test
    fun deepFilterFailureIsReportedAndNeverActive() = runBlocking {
        val engine = engine()
        engine.setEnabled(true)
        engine.onPlaybackChanged(hasTrack = true, isPlaying = true)
        val processor = attach(engine)
        assertThat(
            awaitCondition {
                engine.refresh()
                engine.status.value is AudioProcessingStatus.ModelUnavailable
            },
        ).isTrue()
        processor.feed()
        engine.refresh()
        assertThat(engine.status.value.isActive).isFalse()
        assertThat(engine.state.value.isDeepFilterBypassing).isTrue()
        assertThat(engine.state.value.deepFilterStatus.isBypassing).isTrue()
        assertThat(engine.state.value.deepFilterStatus).isNotEqualTo(DeepFilterStatus.Active)
        assertThat(engine.status.value.detail)
            .isEqualTo("This mode couldn’t start. Try another listening mode. Volume boost is paused.")
    }
}
