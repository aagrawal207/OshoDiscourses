package com.agraabhi.oshodiscourses.denoise

import android.content.Context
import androidx.media3.common.audio.AudioProcessor
import com.agraabhi.oshodiscourses.core.domain.denoise.DenoiseController
import com.agraabhi.oshodiscourses.core.domain.denoise.DenoiseState
import com.agraabhi.oshodiscourses.core.domain.player.AudioMixFailure
import com.agraabhi.oshodiscourses.core.domain.player.AudioProcessingStatus
import com.agraabhi.oshodiscourses.core.domain.player.DeepFilterStatus
import com.agraabhi.oshodiscourses.core.domain.settings.SettingsRepository
import com.agraabhi.oshodiscourses.core.domain.settings.UserSettings
import com.agraabhi.oshodiscourses.core.model.BoostLevel
import com.agraabhi.oshodiscourses.core.model.DenoiseStrength
import com.agraabhi.oshodiscourses.core.model.NoiseReductionMode
import com.agraabhi.oshodiscourses.core.model.VoiceFocusPreset
import com.agraabhi.oshodiscourses.denoise.dsp.DeepFilterModelSource
import com.agraabhi.oshodiscourses.denoise.dsp.DeepFilterProcessor
import com.agraabhi.oshodiscourses.denoise.dsp.DefaultRNNoiseFactory
import com.agraabhi.oshodiscourses.denoise.dsp.DspLog
import com.agraabhi.oshodiscourses.denoise.dsp.NoiseReductionProcessor
import com.agraabhi.oshodiscourses.denoise.dsp.NoiseReductionStream
import com.agraabhi.oshodiscourses.denoise.dsp.RNNoiseFactory
import com.agraabhi.oshodiscourses.denoise.media3.NoiseReductionAudioProcessor
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * DeNoise for the screens and `:playback` (iOS `AudioPlayerService` noise properties). Status
 * needs player state, which `:app` must forward through [onPlaybackChanged].
 */
class DenoiseEngine(
    private val settings: SettingsRepository,
    modelSource: DeepFilterModelSource,
    private val scope: CoroutineScope,
    rnnoiseFactory: RNNoiseFactory = DefaultRNNoiseFactory,
    private val uptimeMillis: () -> Long = { System.nanoTime() / 1_000_000 },
    private val pollIntervalMillis: Long = 500,
) : DenoiseController, DenoiseAudioPipeline {

    private data class Choices(
        val enabled: Boolean,
        val mode: NoiseReductionMode,
        val strength: DenoiseStrength,
        val voiceFocus: VoiceFocusPreset,
        val boostGain: Float,
    ) {
        val outputGain: Float get() = if (boostGain > 1f) boostGain else 1f

        companion object {
            fun from(settings: UserSettings) = Choices(
                enabled = settings.noiseReduction,
                mode = settings.noiseReductionMode,
                strength = settings.denoiseStrength,
                voiceFocus = settings.voiceFocusPreset,
                boostGain = clampBoost(settings.volumeBoost.toFloat()),
            )
        }
    }

    private val lock = Any()
    private val processor = NoiseReductionProcessor(rnnoiseFactory, modelSource)
    private var lastSeenSettings: UserSettings = settings.settings.value
    private var choices = Choices.from(lastSeenSettings)

    private var nextGeneration = 0L
    private var currentGeneration: Long? = null
    private var hasTrack = false
    private var isPlaying = false
    private var playbackFailed = false

    private var previousDiagnostics = NoiseReductionStream.Diagnostics()
    private var lastProcessedAt: Long? = null
    private var monitoringStartedAt: Long? = null
    private var deepFilterStatus: DeepFilterStatus = DeepFilterStatus.Idle
    private var monitor: Job? = null

    private val mutableStatus = MutableStateFlow<AudioProcessingStatus>(AudioProcessingStatus.Off)
    override val status: StateFlow<AudioProcessingStatus> = mutableStatus.asStateFlow()

    private val mutableState = MutableStateFlow(stateLocked())
    override val state: StateFlow<DenoiseState> = mutableState.asStateFlow()

    init {
        configureProcessor(choices)
        refresh()
        scope.launch {
            settings.settings.collect { adoptSettings(it) }
        }
    }

    /** The current chain's model, for instrumented checks. */
    internal val deepFilter: DeepFilterProcessor get() = processor.deepFilter

    // DenoiseAudioPipeline

    override fun createAudioProcessors(): List<AudioProcessor> {
        val audioProcessor = synchronized(lock) {
            nextGeneration += 1
            val generation = nextGeneration
            val context = checkNotNull(processor.makeTapContext(generation))
            currentGeneration = generation
            resetEvidenceLocked()
            context.stream.deepFilter.observeStatus { refresh() }
            DspLog.info(LOG, "Attached chain generation $generation")
            NoiseReductionAudioProcessor(context)
        }
        refresh()
        updateMonitor()
        return listOf(audioProcessor)
    }

    override fun onDiscontinuity() {
        val generation = synchronized(lock) { currentGeneration } ?: return
        processor.requestDiscontinuity(generation)
    }

    /** Player state the status needs: a loaded discourse, actual playback, and playback failure. */
    fun onPlaybackChanged(hasTrack: Boolean, isPlaying: Boolean, failed: Boolean = false) {
        val changed = synchronized(lock) {
            val changed = this.hasTrack != hasTrack || this.isPlaying != isPlaying || playbackFailed != failed
            this.hasTrack = hasTrack
            this.isPlaying = isPlaying
            playbackFailed = failed
            changed
        }
        if (changed) {
            refresh()
            updateMonitor()
        }
    }

    // DenoiseController

    override suspend fun setEnabled(enabled: Boolean) {
        update { it.copy(enabled = enabled) }
        settings.setNoiseReduction(enabled)
    }

    override suspend fun setMode(mode: NoiseReductionMode) {
        update { it.copy(mode = mode) }
        settings.setNoiseReductionMode(mode)
    }

    override suspend fun setStrength(strength: DenoiseStrength) {
        update { it.copy(strength = strength) }
        settings.setDenoiseStrength(strength)
    }

    override suspend fun setVoiceFocus(preset: VoiceFocusPreset) {
        update { it.copy(voiceFocus = preset) }
        settings.setVoiceFocusPreset(preset)
    }

    override suspend fun setBoost(gain: Float) {
        val clamped = clampBoost(gain)
        update { it.copy(boostGain = clamped) }
        settings.setVolumeBoost(clamped.toDouble())
    }

    // Settings

    /** Only fields that changed in the repository are adopted, so a stale emission cannot undo a local change. */
    private fun adoptSettings(next: UserSettings) {
        update { current ->
            val previous = lastSeenSettings
            lastSeenSettings = next
            current.copy(
                enabled = if (next.noiseReduction != previous.noiseReduction) next.noiseReduction else current.enabled,
                mode = if (next.noiseReductionMode != previous.noiseReductionMode) next.noiseReductionMode else current.mode,
                strength = if (next.denoiseStrength != previous.denoiseStrength) next.denoiseStrength else current.strength,
                voiceFocus = if (next.voiceFocusPreset != previous.voiceFocusPreset) next.voiceFocusPreset else current.voiceFocus,
                boostGain = if (next.volumeBoost != previous.volumeBoost) clampBoost(next.volumeBoost.toFloat()) else current.boostGain,
            )
        }
    }

    private fun update(transform: (Choices) -> Choices) {
        val (old, new) = synchronized(lock) {
            val old = choices
            val new = transform(old)
            choices = new
            old to new
        }
        if (old == new) return
        when {
            old.enabled != new.enabled -> {
                // configure() itself detects enabling and activates DeepFilterNet for the current format.
                configureProcessor(new)
                if (new.enabled) {
                    onDiscontinuity()
                } else {
                    // Off plays the original sound; the model's memory is not kept for it.
                    processor.releaseModel()
                }
                synchronized(lock) { resetEvidenceLocked() }
            }
            old.mode != new.mode -> {
                configureProcessor(new)
                synchronized(lock) { resetEvidenceLocked() }
            }
            old.strength != new.strength || old.voiceFocus != new.voiceFocus -> configureProcessor(new)
            else -> processor.setOutputGain(new.outputGain)
        }
        refresh()
        updateMonitor()
    }

    private fun configureProcessor(choices: Choices) {
        processor.configure(
            mode = choices.mode,
            wetMix = choices.strength.wetMix,
            intensity = choices.strength.intensity,
            attenuationLimitDb = choices.strength.attenuationLimitDb,
            voiceFocus = choices.voiceFocus,
            denoiseEnabled = choices.enabled,
            outputGain = choices.outputGain,
        )
    }

    // Status

    private fun updateMonitor() {
        val wanted = synchronized(lock) { choices.enabled && currentGeneration != null && hasTrack }
        synchronized(lock) {
            if (wanted && monitor?.isActive != true) {
                monitor = scope.launch {
                    while (isActive) {
                        delay(pollIntervalMillis)
                        refresh()
                    }
                }
            } else if (!wanted) {
                monitor?.cancel()
                monitor = null
            }
        }
    }

    private fun resetEvidenceLocked() {
        val snapshot = processor.diagnosticsSnapshot()
        previousDiagnostics = if (snapshot.tapGeneration == currentGeneration) snapshot else NoiseReductionStream.Diagnostics()
        lastProcessedAt = null
        monitoringStartedAt = null
    }

    /** Samples recent buffer outcomes; model readiness alone never reports Active. */
    fun refresh() {
        val (next, outcome) = synchronized(lock) {
            val status = computeStatusLocked()
            val transition = if (mutableStatus.value != status) status to choices.mode.rawValue else null
            mutableStatus.value = status
            mutableState.value = stateLocked()
            status to transition
        }
        if (outcome != null) {
            val message = "method=${outcome.second} outcome=${next.outcome}"
            if (next.isIssue) DspLog.error(LOG, message) else DspLog.info(LOG, message)
        }
    }

    private fun computeStatusLocked(): AudioProcessingStatus {
        if (!choices.enabled) {
            deepFilterStatus = DeepFilterStatus.Idle
            return AudioProcessingStatus.Off
        }
        if (!hasTrack) {
            deepFilterStatus = DeepFilterStatus.Idle
            return AudioProcessingStatus.WaitingForPlayback
        }
        if (playbackFailed) {
            deepFilterStatus = DeepFilterStatus.Idle
            return AudioProcessingStatus.SetupFailed(AudioMixFailure.PLAYBACK)
        }
        val generation = currentGeneration
        if (generation == null) {
            deepFilterStatus = DeepFilterStatus.Idle
            return AudioProcessingStatus.Preparing
        }
        val snapshot = processor.diagnosticsSnapshot()
        if (snapshot.tapGeneration != generation) {
            previousDiagnostics = NoiseReductionStream.Diagnostics()
            lastProcessedAt = null
            monitoringStartedAt = null
            deepFilterStatus = DeepFilterStatus.Idle
            return AudioProcessingStatus.Preparing
        }
        if (previousDiagnostics.tapGeneration != snapshot.tapGeneration) {
            previousDiagnostics = NoiseReductionStream.Diagnostics(tapGeneration = snapshot.tapGeneration)
            lastProcessedAt = null
            monitoringStartedAt = null
        }
        val previous = previousDiagnostics
        val processed = snapshot.processedBuffers - previous.processedBuffers
        val invalid = snapshot.invalidBuffers - previous.invalidBuffers
        val bypassed = (snapshot.modelBypassedBuffers - previous.modelBypassedBuffers) +
            (snapshot.disabledBuffers - previous.disabledBuffers) +
            (snapshot.lockContendedBuffers - previous.lockContendedBuffers)
        previousDiagnostics = snapshot
        val mode = choices.mode
        deepFilterStatus = if (mode == NoiseReductionMode.DEEP_FILTER_NET) snapshot.deepFilterStatus else DeepFilterStatus.Idle

        if (snapshot.sourceReadFailed) {
            lastProcessedAt = null
            return AudioProcessingStatus.SourceError
        }
        if (invalid > 0 || snapshot.deepFilterStatus == DeepFilterStatus.UnsupportedAudioFormat ||
            snapshot.deepFilterStatus is DeepFilterStatus.UnsupportedSampleRate
        ) {
            lastProcessedAt = null
            return AudioProcessingStatus.UnsupportedFormat
        }
        if (!snapshot.isPrepared) {
            lastProcessedAt = null
            monitoringStartedAt = null
            return AudioProcessingStatus.Preparing
        }
        if (mode == NoiseReductionMode.DEEP_FILTER_NET) {
            when (deepFilterStatus) {
                DeepFilterStatus.Loading -> {
                    lastProcessedAt = null
                    return AudioProcessingStatus.LoadingModel
                }
                DeepFilterStatus.Idle -> {
                    lastProcessedAt = null
                    return AudioProcessingStatus.Preparing
                }
                DeepFilterStatus.Active -> Unit
                else -> {
                    lastProcessedAt = null
                    return AudioProcessingStatus.ModelUnavailable(deepFilterStatus)
                }
            }
        }
        if (!isPlaying) {
            lastProcessedAt = null
            monitoringStartedAt = null
            return AudioProcessingStatus.WaitingForPlayback
        }
        if (snapshot.resetPending) {
            lastProcessedAt = null
            return AudioProcessingStatus.Preparing
        }

        val now = uptimeMillis()
        val started = monitoringStartedAt ?: now.also { monitoringStartedAt = it }
        val lastProcessed = lastProcessedAt
        return when {
            processed > 0 -> {
                lastProcessedAt = now
                AudioProcessingStatus.Active
            }
            bypassed > 0 -> {
                lastProcessedAt = null
                AudioProcessingStatus.Bypassing
            }
            lastProcessed != null && now - lastProcessed < RECENT_MILLIS -> AudioProcessingStatus.Active
            now - started >= RECENT_MILLIS -> AudioProcessingStatus.WaitingForAudio
            mode == NoiseReductionMode.DEEP_FILTER_NET -> AudioProcessingStatus.ModelReady
            else -> AudioProcessingStatus.Preparing
        }
    }

    private fun stateLocked(): DenoiseState = DenoiseState(
        isEnabled = choices.enabled,
        mode = choices.mode,
        strength = choices.strength,
        voiceFocus = choices.voiceFocus,
        boostGain = choices.boostGain,
        status = mutableStatus.value,
        deepFilterStatus = deepFilterStatus,
        isProcessorAttached = currentGeneration != null,
    )

    companion object {
        private const val LOG = "AudioProcessing"

        /** Processed buffers within this window still count as active between polls. */
        private const val RECENT_MILLIS = 2_000L

        private fun clampBoost(gain: Float): Float =
            if (gain.isFinite()) gain.coerceIn(1f, BoostLevel.MAXIMUM_GAIN) else BoostLevel.MEDIUM.gain

        /** The app's engine, loading the bundled model from APK assets. */
        fun create(context: Context, settings: SettingsRepository, scope: CoroutineScope): DenoiseEngine =
            DenoiseEngine(settings, AssetDeepFilterModel(context), scope)
    }
}
