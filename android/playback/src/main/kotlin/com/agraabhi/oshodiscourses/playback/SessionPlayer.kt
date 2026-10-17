package com.agraabhi.oshodiscourses.playback

import android.os.Bundle
import androidx.annotation.OptIn
import androidx.media3.common.ForwardingPlayer
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.CommandButton
import androidx.media3.session.SessionCommand
import com.agraabhi.oshodiscourses.core.domain.player.PlayerController

/** Custom session commands and the notification / lock-screen buttons (iOS remote commands). */
object PlaybackSessionCommands {
    const val ACTION_SKIP_BACKWARD: String = "com.agraabhi.oshodiscourses.playback.SKIP_BACKWARD"
    const val ACTION_SKIP_FORWARD: String = "com.agraabhi.oshodiscourses.playback.SKIP_FORWARD"

    val skipBackward: SessionCommand = SessionCommand(ACTION_SKIP_BACKWARD, Bundle.EMPTY)
    val skipForward: SessionCommand = SessionCommand(ACTION_SKIP_FORWARD, Bundle.EMPTY)

    /** Skips take the back/forward slots like the iOS lock screen; previous/next move to overflow. */
    @OptIn(UnstableApi::class)
    fun mediaButtons(): List<CommandButton> = listOf(
        CommandButton.Builder(CommandButton.ICON_SKIP_BACK_15)
            .setDisplayName("Skip back 15 seconds")
            .setSessionCommand(skipBackward)
            .setSlots(CommandButton.SLOT_BACK)
            .build(),
        CommandButton.Builder(CommandButton.ICON_SKIP_FORWARD_30)
            .setDisplayName("Skip forward 30 seconds")
            .setSessionCommand(skipForward)
            .setSlots(CommandButton.SLOT_FORWARD)
            .build(),
        CommandButton.Builder(CommandButton.ICON_PREVIOUS)
            .setDisplayName("Previous")
            .setPlayerCommand(Player.COMMAND_SEEK_TO_PREVIOUS)
            .setSlots(CommandButton.SLOT_OVERFLOW)
            .build(),
        CommandButton.Builder(CommandButton.ICON_NEXT)
            .setDisplayName("Next")
            .setPlayerCommand(Player.COMMAND_SEEK_TO_NEXT)
            .setSlots(CommandButton.SLOT_OVERFLOW)
            .build(),
    )
}

/**
 * The player the media session sees. Remote transport calls go through [engine], so they save
 * progress, keep seek history and run completion exactly like the in-app controls.
 */
@OptIn(UnstableApi::class)
internal class SessionPlayer(player: Player, private val engine: PlaybackEngine) : ForwardingPlayer(player) {
    // The engine prepares on play; letting the session prepare would start a load the engine did not plan.
    override fun prepare() = Unit

    override fun play() = engine.setPlayingNow(true)

    override fun pause() = engine.setPlayingNow(false)

    override fun setPlayWhenReady(playWhenReady: Boolean) = engine.setPlayingNow(playWhenReady)

    // iOS exposes no stop command; a headset stop key pauses and keeps the talk loaded.
    override fun stop() = engine.setPlayingNow(false)

    override fun seekTo(positionMs: Long) = engine.seekWithHistoryNow(positionMs / 1000.0)

    override fun seekTo(mediaItemIndex: Int, positionMs: Long) {
        if (mediaItemIndex == engine.currentIndexNow) engine.seekWithHistoryNow(positionMs / 1000.0) else engine.playQueueItemNow(mediaItemIndex)
    }

    override fun seekToDefaultPosition() = engine.seekNow(0.0)

    override fun seekToDefaultPosition(mediaItemIndex: Int) {
        if (mediaItemIndex == engine.currentIndexNow) engine.seekNow(0.0) else engine.playQueueItemNow(mediaItemIndex)
    }

    override fun getSeekBackIncrement(): Long = (PlayerController.SKIP_BACKWARD_SECONDS * 1000).toLong()

    override fun getSeekForwardIncrement(): Long = (PlayerController.SKIP_FORWARD_SECONDS * 1000).toLong()

    override fun seekBack() = engine.skipBackwardNow(PlayerController.SKIP_BACKWARD_SECONDS)

    override fun seekForward() = engine.skipForwardNow(PlayerController.SKIP_FORWARD_SECONDS)

    override fun seekToPrevious() = engine.skipToPreviousNow()

    override fun seekToPreviousMediaItem() = engine.skipToPreviousNow()

    override fun seekToNext() = engine.skipToNextNow()

    override fun seekToNextMediaItem() = engine.skipToNextNow()

    override fun setPlaybackSpeed(speed: Float) = engine.setRateNow(speed)

    override fun setPlaybackParameters(playbackParameters: PlaybackParameters) = engine.setRateNow(playbackParameters.speed)
}
