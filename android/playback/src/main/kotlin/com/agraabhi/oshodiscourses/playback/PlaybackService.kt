package com.agraabhi.oshodiscourses.playback

import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.os.Bundle
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaController
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionResult
import androidx.media3.session.SessionToken
import com.agraabhi.oshodiscourses.core.domain.player.PlayerController
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture

/** Implemented by the `Application`, so the system-created service finds the process-wide engine. */
interface PlaybackEngineProvider {
    val playbackEngine: PlaybackEngine
}

/**
 * Hosts the media session behind the notification, lock screen and headset controls. The engine
 * owns the player; Media3 keeps this service in the foreground while audio plays.
 */
@OptIn(UnstableApi::class)
class PlaybackService : MediaSessionService() {
    private var session: MediaSession? = null

    override fun onCreate() {
        super.onCreate()
        val engine = (application as PlaybackEngineProvider).playbackEngine
        val builder = MediaSession.Builder(this, engine.sessionPlayer)
            .setCallback(PlaybackSessionCallback(engine))
            .setMediaButtonPreferences(PlaybackSessionCommands.mediaButtons())
        launchIntent()?.let(builder::setSessionActivity)
        session = builder.build()
        Log.i(TAG, "outcome=session_created")
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = session

    override fun onDestroy() {
        // The engine outlives the service and keeps its player; only the session goes.
        session?.release()
        session = null
        Log.i(TAG, "outcome=session_released")
        super.onDestroy()
    }

    private fun launchIntent(): PendingIntent? {
        val intent = packageManager.getLaunchIntentForPackage(packageName) ?: return null
        return PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    private companion object {
        const val TAG = "PlaybackService"
    }
}

@OptIn(UnstableApi::class)
internal class PlaybackSessionCallback(private val engine: PlaybackEngine) : MediaSession.Callback {
    override fun onConnect(session: MediaSession, controller: MediaSession.ControllerInfo): MediaSession.ConnectionResult {
        val commands = MediaSession.ConnectionResult.DEFAULT_SESSION_COMMANDS.buildUpon()
            .add(PlaybackSessionCommands.skipBackward)
            .add(PlaybackSessionCommands.skipForward)
            .build()
        return MediaSession.ConnectionResult.AcceptedResultBuilder(session, controller)
            .setAvailableSessionCommands(commands)
            .build()
    }

    override fun onCustomCommand(
        session: MediaSession,
        controller: MediaSession.ControllerInfo,
        customCommand: SessionCommand,
        args: Bundle,
    ): ListenableFuture<SessionResult> {
        when (customCommand.customAction) {
            PlaybackSessionCommands.ACTION_SKIP_BACKWARD -> engine.skipBackwardNow(PlayerController.SKIP_BACKWARD_SECONDS)
            PlaybackSessionCommands.ACTION_SKIP_FORWARD -> engine.skipForwardNow(PlayerController.SKIP_FORWARD_SECONDS)
            else -> return Futures.immediateFuture(SessionResult(SessionResult.RESULT_ERROR_NOT_SUPPORTED))
        }
        return Futures.immediateFuture(SessionResult(SessionResult.RESULT_SUCCESS))
    }
}

/** Keeps [PlaybackService] bound while a discourse is loaded, so its session and notification exist. */
interface PlaybackServiceBinding {
    fun connect()

    fun release()

    object None : PlaybackServiceBinding {
        override fun connect() = Unit

        override fun release() = Unit
    }
}

/** Binds the service through a `MediaController`, the way Media3 expects a session service to start. */
class MediaControllerServiceBinding(private val context: Context) : PlaybackServiceBinding {
    private var controller: ListenableFuture<MediaController>? = null

    override fun connect() {
        if (controller != null) return
        val token = SessionToken(context, ComponentName(context, PlaybackService::class.java))
        var future: ListenableFuture<MediaController>? = null
        future = MediaController.Builder(context, token)
            .setListener(object : MediaController.Listener {
                override fun onDisconnected(controller: MediaController) {
                    // The service was destroyed; the next playback request binds it again.
                    if (this@MediaControllerServiceBinding.controller === future) this@MediaControllerServiceBinding.controller = null
                }
            })
            .buildAsync()
        controller = future
    }

    override fun release() {
        controller?.let(MediaController::releaseFuture)
        controller = null
    }
}
