package com.agraabhi.oshodiscourses.core.domain.denoise

import com.agraabhi.oshodiscourses.core.domain.player.AudioProcessingStatus
import com.agraabhi.oshodiscourses.core.domain.player.DeepFilterStatus
import com.agraabhi.oshodiscourses.core.model.BoostLevel
import com.agraabhi.oshodiscourses.core.model.DenoiseStrength
import com.agraabhi.oshodiscourses.core.model.NoiseReductionMode
import com.agraabhi.oshodiscourses.core.model.VoiceFocusPreset
import kotlinx.coroutines.flow.StateFlow

/**
 * The DeNoise screen's model, shared by Player > DeNoise and Settings > DeNoise (iOS
 * `AudioPlayerService` noise properties over `NoiseReductionProcessor`). Choices persist to
 * `SettingsRepository` and apply live: strength, Voice Focus and boost keep the current
 * processor and its neural history; only enabling or changing mode rebuilds it.
 */
interface DenoiseController {
    val state: StateFlow<DenoiseState>

    suspend fun setEnabled(enabled: Boolean)

    suspend fun setMode(mode: NoiseReductionMode)

    suspend fun setStrength(strength: DenoiseStrength)

    /** Used only with DeepFilterNet. */
    suspend fun setVoiceFocus(preset: VoiceFocusPreset)

    /** Gain 1..[BoostLevel.MAXIMUM_GAIN]; 1 turns Boost off. */
    suspend fun setBoost(gain: Float)
}

data class DenoiseState(
    val isEnabled: Boolean = false,
    val mode: NoiseReductionMode = NoiseReductionMode.DEEP_FILTER_NET,
    val strength: DenoiseStrength = DenoiseStrength.MEDIUM,
    val voiceFocus: VoiceFocusPreset = VoiceFocusPreset.LIFT,
    /** The listener's saved gain, independent of whether it applies right now. */
    val boostGain: Float = 2f,
    val status: AudioProcessingStatus = AudioProcessingStatus.Off,
    val deepFilterStatus: DeepFilterStatus = DeepFilterStatus.Idle,
    val isProcessorAttached: Boolean = false,
) {
    /** Boost applies only while the current processor confirms it is processing audio. */
    val isBoostAvailable: Boolean get() = isEnabled && isProcessorAttached && status.isActive

    val isDeepFilterBypassing: Boolean
        get() = isEnabled && mode == NoiseReductionMode.DEEP_FILTER_NET && !status.isActive

    val boostLevel: BoostLevel? get() = BoostLevel.entries.firstOrNull { it.gain == boostGain }

    /** VoiceOver-style summary for the DeNoise button. */
    val accessibilityValue: String
        get() {
            if (!isEnabled) return "Off"
            var value = "On, ${mode.displayName}, ${strength.label} noise reduction"
            if (mode == NoiseReductionMode.DEEP_FILTER_NET) value += ", quiet speech ${voiceFocus.displayName}"
            return "$value. ${status.label}"
        }
}
