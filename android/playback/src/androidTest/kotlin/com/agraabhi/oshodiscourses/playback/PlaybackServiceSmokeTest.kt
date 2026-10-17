package com.agraabhi.oshodiscourses.playback

import android.content.ComponentName
import android.os.Bundle
import android.os.SystemClock
import androidx.media3.session.MediaController
import androidx.media3.session.SessionResult
import androidx.media3.session.SessionToken
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.agraabhi.oshodiscourses.core.domain.player.QueueItem
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.TimeUnit

/** Plays a bundled three-second tone through the real ExoPlayer, renderers and media session service. */
@RunWith(AndroidJUnit4::class)
class PlaybackServiceSmokeTest {
    private val app: SmokeTestApplication = ApplicationProvider.getApplicationContext()
    private val engine get() = app.playbackEngine
    private var controller: MediaController? = null

    @After
    fun tearDown() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync { controller?.release() }
        runBlocking { withContext(Dispatchers.Main) { engine.stop() } }
    }

    @Test
    fun playsAToneAndExposesItThroughTheSession() {
        runBlocking {
            withContext(Dispatchers.Main) {
                engine.playQueue(listOf(QueueItem("tone", "asset:///tone.wav", "Tone", "Smoke")))
            }
        }
        waitUntil("the tone plays") { engine.state.value.isPlaying && engine.state.value.currentTime >= 0.5 }
        assertThat(engine.state.value.duration).isWithin(0.1).of(3.0)

        val token = SessionToken(app, ComponentName(app, PlaybackService::class.java))
        val connected = MediaController.Builder(app, token).buildAsync().get(10, TimeUnit.SECONDS)
        controller = connected
        var mediaId: String? = null
        var title: CharSequence? = null
        var playing = false
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            mediaId = connected.currentMediaItem?.mediaId
            title = connected.mediaMetadata.title
            playing = connected.isPlaying
        }
        assertThat(mediaId).isEqualTo("tone")
        assertThat(title.toString()).isEqualTo("Tone")
        assertThat(playing).isTrue()

        runOnMain { connected.pause() }
        waitUntil("the session pause reaches the engine") { !engine.state.value.isPlaying }
        val future = runOnMain { connected.sendCustomCommand(PlaybackSessionCommands.skipBackward, Bundle.EMPTY) }
        assertThat(future.get(5, TimeUnit.SECONDS).resultCode).isEqualTo(SessionResult.RESULT_SUCCESS)
        waitUntil("skip back lands at the start") { engine.state.value.currentTime < 0.1 }

        runOnMain { connected.play() }
        waitUntil("the tone finishes and unloads") { !engine.state.value.hasTrack }
    }

    private fun <T> runOnMain(block: () -> T): T {
        var value: T? = null
        InstrumentationRegistry.getInstrumentation().runOnMainSync { value = block() }
        @Suppress("UNCHECKED_CAST")
        return value as T
    }

    private fun waitUntil(what: String, timeoutMs: Long = 10_000, condition: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + timeoutMs
        while (SystemClock.uptimeMillis() < deadline) {
            if (condition()) return
            SystemClock.sleep(50)
        }
        throw AssertionError("Timed out waiting until $what")
    }
}
