package com.agraabhi.oshodiscourses.playback

import android.content.Context
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.DefaultAudioSink
import com.agraabhi.oshodiscourses.denoise.DenoiseAudioPipeline

/**
 * Puts the DeNoise chain ahead of ExoPlayer's own processors, so noise reduction sees the
 * source-rate signal before the speed change, as the iOS tap does on the asset track.
 */
@OptIn(UnstableApi::class)
class DenoiseRenderersFactory(
    context: Context,
    private val pipeline: DenoiseAudioPipeline,
) : DefaultRenderersFactory(context) {
    override fun buildAudioSink(
        context: Context,
        enableFloatOutput: Boolean,
        enableAudioOutputPlaybackParams: Boolean,
    ): AudioSink =
        DefaultAudioSink.Builder(context)
            .setEnableFloatOutput(enableFloatOutput)
            .setEnableAudioOutputPlaybackParameters(enableAudioOutputPlaybackParams)
            .setAudioProcessors(pipeline.createAudioProcessors().toTypedArray())
            .build()
}
