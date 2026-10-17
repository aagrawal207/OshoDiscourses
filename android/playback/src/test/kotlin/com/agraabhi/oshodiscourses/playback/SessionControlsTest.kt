package com.agraabhi.oshodiscourses.playback

import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.media3.common.MediaItem
import androidx.media3.exoplayer.audio.AudioRendererEventListener
import androidx.media3.exoplayer.audio.MediaCodecAudioRenderer
import androidx.media3.exoplayer.video.VideoRendererEventListener
import androidx.media3.session.CommandButton
import androidx.media3.session.MediaSession
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionResult
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.agraabhi.oshodiscourses.core.domain.progress.PlaybackProgress
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

/** Remote controls (notification, lock screen, headset) route through the engine, as iOS remote commands do. */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(AndroidJUnit4::class)
@Config(sdk = [36])
class SessionControlsTest {
    private val context: Context = ApplicationProvider.getApplicationContext()

    private fun test(body: suspend TestScope.() -> Unit) = runTest(UnconfinedTestDispatcher()) { body() }

    private suspend fun TestScope.playing(): EngineFixture {
        val f = EngineFixture(backgroundScope, context)
        f.engine.play(BIRD[0])
        f.runUntil { f.state.isPlaying }
        return f
    }

    @Test
    fun sessionTransportCallsReachTheEngine() = test {
        val f = playing()
        val remote = f.engine.sessionPlayer
        remote.seekTo(100_000)
        assertThat(f.state.currentTime).isEqualTo(100.0)
        assertThat(f.state.previousPosition).isNotNull()

        remote.seekForward()
        assertThat(f.playerSeconds).isWithin(0.5).of(130.0)
        remote.seekBack()
        assertThat(f.playerSeconds).isWithin(0.5).of(115.0)
        assertThat(remote.seekBackIncrement).isEqualTo(15_000)
        assertThat(remote.seekForwardIncrement).isEqualTo(30_000)

        remote.pause()
        assertThat(f.state.isPlaying).isFalse()
        assertThat(f.progress.getPosition(BIRD[0])).isWithin(0.5).of(115.0)
        remote.play()
        assertThat(f.state.isPlaying).isTrue()

        remote.setPlaybackSpeed(1.12f)
        assertThat(f.state.playbackRate).isEqualTo(1.1f)
        assertThat(f.settings.settings.value.defaultPlaybackRate).isEqualTo(1.1f.toDouble())

        remote.seekToNext()
        f.runUntil { f.state.currentTrackId == BIRD[1] && f.state.isPlaying }
        remote.seekToPrevious()
        f.runUntil { f.state.currentTrackId == BIRD[0] }
    }

    @Test
    fun headsetStopPausesAndKeepsTheTalk() = test {
        val f = playing()
        f.engine.sessionPlayer.stop()
        assertThat(f.state.isPlaying).isFalse()
        assertThat(f.state.currentTrackId).isEqualTo(BIRD[0])
    }

    @Test
    fun customSkipCommandsUseFifteenAndThirtySeconds() = test {
        val f = playing()
        f.engine.seek(60.0)
        val session = MediaSession.Builder(context, f.engine.sessionPlayer)
            .setId("test-${System.nanoTime()}")
            .setMediaButtonPreferences(PlaybackSessionCommands.mediaButtons())
            .build()
        try {
            val callback = PlaybackSessionCallback(f.engine)
            val controller = MediaSession.ControllerInfo.createTestOnlyControllerInfo(
                "com.example.headset", 0, 0, 0, 0, false, Bundle.EMPTY, false,
            )
            val connection = callback.onConnect(session, controller)
            assertThat(connection.isAccepted).isTrue()
            assertThat(connection.availableSessionCommands.contains(PlaybackSessionCommands.skipBackward)).isTrue()
            assertThat(connection.availableSessionCommands.contains(PlaybackSessionCommands.skipForward)).isTrue()

            val forward = callback.onCustomCommand(session, controller, PlaybackSessionCommands.skipForward, Bundle.EMPTY)
            assertThat(forward.get().resultCode).isEqualTo(SessionResult.RESULT_SUCCESS)
            assertThat(f.playerSeconds).isWithin(0.5).of(90.0)
            callback.onCustomCommand(session, controller, PlaybackSessionCommands.skipBackward, Bundle.EMPTY)
            assertThat(f.playerSeconds).isWithin(0.5).of(75.0)

            val unknown = callback.onCustomCommand(session, controller, SessionCommand("other", Bundle.EMPTY), Bundle.EMPTY)
            assertThat(unknown.get().resultCode).isEqualTo(SessionResult.RESULT_ERROR_NOT_SUPPORTED)
        } finally {
            session.release()
        }
    }

    @Test
    fun playbackResumptionRestoresTheLastTalkAndKeepsTheEngineQueue() = test {
        val f = EngineFixture(
            backgroundScope,
            context,
            downloaded = setOf(BIRD[0], BIRD[1]),
            progress = PlaybackProgress(positions = mapOf(BIRD[1] to 120.0), recentlyPlayed = listOf(BIRD[1])),
        )
        val session = MediaSession.Builder(context, f.engine.sessionPlayer).setId("test-${System.nanoTime()}").build()
        try {
            val controller = MediaSession.ControllerInfo.createTestOnlyControllerInfo(
                "com.example.bluetooth", 0, 0, 0, 0, false, Bundle.EMPTY, false,
            )
            val resumed = PlaybackSessionCallback(f.engine).onPlaybackResumption(session, controller, true).get()
            assertThat(resumed.mediaItems.map { it.mediaId }).containsExactly(BIRD[0], BIRD[1]).inOrder()
            assertThat(resumed.startIndex).isEqualTo(1)
            assertThat(resumed.startPositionMs).isEqualTo(120_000)
            assertThat(f.state.currentTrackId).isEqualTo(BIRD[1])

            // Media3 then sets those items and plays; the engine keeps its queue and restores the position.
            f.engine.sessionPlayer.setMediaItems(resumed.mediaItems, resumed.startIndex, resumed.startPositionMs)
            f.engine.sessionPlayer.play()
            f.runUntil { f.state.isPlaying }
            assertThat(f.state.currentTrackId).isEqualTo(BIRD[1])
            assertThat(f.state.currentTime).isWithin(0.5).of(120.0)
        } finally {
            session.release()
        }
    }

    @Test
    fun aHeadsetPlayAfterALaunchRestoreResumesTheRestoredTalk() = test {
        val f = EngineFixture(
            backgroundScope,
            context,
            progress = PlaybackProgress(positions = mapOf(BIRD[1] to 240.0), recentlyPlayed = listOf(BIRD[1])),
        )
        assertThat(f.engine.restoreLastSession()).isTrue()
        val session = MediaSession.Builder(context, f.engine.sessionPlayer).setId("test-${System.nanoTime()}").build()
        try {
            // The restore left ExoPlayer empty, which is what makes Media3 ask for resumption.
            assertThat(f.engine.sessionPlayer.mediaItemCount).isEqualTo(0)
            val controller = MediaSession.ControllerInfo.createTestOnlyControllerInfo(
                "com.example.bluetooth", 0, 0, 0, 0, false, Bundle.EMPTY, false,
            )
            val resumed = PlaybackSessionCallback(f.engine).onPlaybackResumption(session, controller, true).get()
            assertThat(resumed.mediaItems.map { it.mediaId }).containsExactlyElementsIn(BIRD).inOrder()
            assertThat(resumed.startIndex).isEqualTo(1)
            assertThat(resumed.startPositionMs).isEqualTo(240_000)

            f.engine.sessionPlayer.setMediaItems(resumed.mediaItems, resumed.startIndex, resumed.startPositionMs)
            f.engine.sessionPlayer.play()
            f.runUntil { f.state.isPlaying }
            assertThat(f.state.currentTrackId).isEqualTo(BIRD[1])
            assertThat(f.state.currentTime).isWithin(0.5).of(240.0)
            assertThat(f.engine.sessionPlayer.mediaItemCount).isEqualTo(3)
        } finally {
            session.release()
        }
    }

    @Test
    fun playbackResumptionFailsWithNothingDownloaded() = test {
        val f = EngineFixture(backgroundScope, context, downloaded = emptySet(), progress = PlaybackProgress(recentlyPlayed = listOf(BIRD[0])))
        val session = MediaSession.Builder(context, f.engine.sessionPlayer).setId("test-${System.nanoTime()}").build()
        try {
            val controller = MediaSession.ControllerInfo.createTestOnlyControllerInfo(
                "com.example.bluetooth", 0, 0, 0, 0, false, Bundle.EMPTY, false,
            )
            val result = PlaybackSessionCallback(f.engine).onPlaybackResumption(session, controller, true)
            assertThat(runCatching { result.get() }.isFailure).isTrue()
            assertThat(f.state.hasTrack).isFalse()
        } finally {
            session.release()
        }
    }

    @Test
    fun controllerPlaylistsBecomeEngineQueuesOfDownloadedTalks() = test {
        val f = EngineFixture(backgroundScope, context, downloaded = setOf(BIRD[0], BIRD[2]))
        val items = BIRD.take(3).map { MediaItem.Builder().setMediaId(it).build() }
        f.engine.sessionPlayer.setMediaItems(items, 2, 30_000)
        assertThat(f.state.queue.map { it.id }).containsExactly(BIRD[0], BIRD[2]).inOrder()
        assertThat(f.state.currentTrackId).isEqualTo(BIRD[2])
        assertThat(f.state.isPlaying).isFalse()
        assertThat(f.state.currentTime).isEqualTo(30.0)
    }

    @Test
    fun mediaButtonsPutTheSkipsInTheBackAndForwardSlots() {
        val buttons = PlaybackSessionCommands.mediaButtons()
        val back = buttons.first { it.sessionCommand == PlaybackSessionCommands.skipBackward }
        val forward = buttons.first { it.sessionCommand == PlaybackSessionCommands.skipForward }
        assertThat(back.icon).isEqualTo(CommandButton.ICON_SKIP_BACK_15)
        assertThat(back.slots.get(0)).isEqualTo(CommandButton.SLOT_BACK)
        assertThat(back.displayName.toString()).isEqualTo("Skip back 15 seconds")
        assertThat(forward.icon).isEqualTo(CommandButton.ICON_SKIP_FORWARD_30)
        assertThat(forward.slots.get(0)).isEqualTo(CommandButton.SLOT_FORWARD)
        assertThat(forward.displayName.toString()).isEqualTo("Skip forward 30 seconds")
        assertThat(buttons.map { it.displayName.toString() }).containsAtLeast("Previous", "Next")
    }

    @Test
    fun theAudioSinkCarriesTheDenoiseChain() {
        val pipeline = RecordingPipeline()
        val renderers = DenoiseRenderersFactory(context, pipeline).createRenderers(
            Handler(Looper.getMainLooper()),
            object : VideoRendererEventListener {},
            object : AudioRendererEventListener {},
            { },
            { },
        )
        assertThat(pipeline.processorRequests).isEqualTo(1)
        assertThat(renderers.any { it is MediaCodecAudioRenderer }).isTrue()
    }
}
