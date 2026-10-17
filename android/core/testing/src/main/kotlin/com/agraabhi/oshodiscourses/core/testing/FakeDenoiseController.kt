package com.agraabhi.oshodiscourses.core.testing

import com.agraabhi.oshodiscourses.core.domain.denoise.DenoiseController
import com.agraabhi.oshodiscourses.core.domain.denoise.DenoiseState
import com.agraabhi.oshodiscourses.core.domain.player.AudioProcessingStatus
import com.agraabhi.oshodiscourses.core.model.BoostLevel
import com.agraabhi.oshodiscourses.core.model.DenoiseStrength
import com.agraabhi.oshodiscourses.core.model.NoiseReductionMode
import com.agraabhi.oshodiscourses.core.model.VoiceFocusPreset
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update

/** Enabling reports [AudioProcessingStatus.Active] at once, so Boost is available. */
class FakeDenoiseController(initial: DenoiseState = DenoiseState()) : DenoiseController {
    override val state = MutableStateFlow(initial)

    override suspend fun setEnabled(enabled: Boolean) = state.update {
        it.copy(
            isEnabled = enabled,
            isProcessorAttached = enabled,
            status = if (enabled) AudioProcessingStatus.Active else AudioProcessingStatus.Off,
        )
    }

    override suspend fun setMode(mode: NoiseReductionMode) = state.update { it.copy(mode = mode) }

    override suspend fun setStrength(strength: DenoiseStrength) = state.update { it.copy(strength = strength) }

    override suspend fun setVoiceFocus(preset: VoiceFocusPreset) = state.update { it.copy(voiceFocus = preset) }

    override suspend fun setBoost(gain: Float) = state.update { it.copy(boostGain = gain.coerceIn(1f, BoostLevel.MAXIMUM_GAIN)) }
}
