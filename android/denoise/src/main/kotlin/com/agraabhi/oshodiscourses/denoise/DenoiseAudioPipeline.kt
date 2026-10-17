package com.agraabhi.oshodiscourses.denoise

import androidx.media3.common.audio.AudioProcessor
import com.agraabhi.oshodiscourses.core.domain.player.AudioProcessingStatus
import kotlinx.coroutines.flow.StateFlow

/**
 * Seam between `:playback` and `:denoise`. The player asks for a fresh chain for each
 * audio sink it builds, and reports seeks and source changes so DSP history is reset.
 */
interface DenoiseAudioPipeline {
    fun createAudioProcessors(): List<AudioProcessor>

    fun onDiscontinuity()

    val status: StateFlow<AudioProcessingStatus>
}
