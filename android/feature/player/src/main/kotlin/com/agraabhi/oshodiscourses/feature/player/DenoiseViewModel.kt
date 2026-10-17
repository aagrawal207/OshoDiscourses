package com.agraabhi.oshodiscourses.feature.player

import androidx.compose.runtime.Composable
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.agraabhi.oshodiscourses.core.domain.denoise.DenoiseController
import com.agraabhi.oshodiscourses.core.domain.denoise.DenoiseState
import com.agraabhi.oshodiscourses.core.model.BoostLevel
import com.agraabhi.oshodiscourses.core.model.DenoiseStrength
import com.agraabhi.oshodiscourses.core.model.NoiseReductionMode
import com.agraabhi.oshodiscourses.core.model.VoiceFocusPreset
import com.agraabhi.oshodiscourses.core.ui.LocalAppServices
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/** The DeNoise screen's state holder; the controller persists every choice and applies it live. */
class DenoiseViewModel(private val denoise: DenoiseController) : ViewModel() {
    val state: StateFlow<DenoiseState> = denoise.state

    fun setEnabled(enabled: Boolean) = launch { denoise.setEnabled(enabled) }

    fun setMode(mode: NoiseReductionMode) = launch { denoise.setMode(mode) }

    fun setStrength(strength: DenoiseStrength) = launch { denoise.setStrength(strength) }

    fun setVoiceFocus(preset: VoiceFocusPreset) = launch { denoise.setVoiceFocus(preset) }

    fun setBoost(level: BoostLevel) = launch { denoise.setBoost(level.gain) }

    private fun launch(block: suspend () -> Unit) {
        viewModelScope.launch { block() }
    }
}

@Composable
internal fun denoiseViewModel(): DenoiseViewModel {
    val services = LocalAppServices.current
    return viewModel(key = "denoise-${System.identityHashCode(services)}") { DenoiseViewModel(services.denoise) }
}
