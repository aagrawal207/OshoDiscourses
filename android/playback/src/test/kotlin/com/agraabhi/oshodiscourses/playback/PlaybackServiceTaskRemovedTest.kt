package com.agraabhi.oshodiscourses.playback

import android.app.Application
import android.content.Intent
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.annotation.Config

/** Hands the system-created service the test's engine, as `OshoApplication` does in the app. */
class EngineProviderApplication : Application(), PlaybackEngineProvider {
    var engine: PlaybackEngine? = null

    override val playbackEngine: PlaybackEngine get() = checkNotNull(engine)
}

@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(AndroidJUnit4::class)
@Config(sdk = [36], application = EngineProviderApplication::class)
class PlaybackServiceTaskRemovedTest {
    @Test
    fun swipingTheTaskAwaySavesThePositionAndKeepsPlaying() = runTest(UnconfinedTestDispatcher()) {
        val app = ApplicationProvider.getApplicationContext<EngineProviderApplication>()
        val f = EngineFixture(backgroundScope, app)
        app.engine = f.engine
        f.engine.play(BIRD[0])
        f.runUntil { f.state.isPlaying }
        f.playUntil(42.0)

        val service = Robolectric.buildService(PlaybackService::class.java).create()
        try {
            service.get().onTaskRemoved(Intent())
            assertThat(f.progress.getPosition(BIRD[0])).isWithin(0.5).of(42.0)
            assertThat(f.state.isPlaying).isTrue()
        } finally {
            service.destroy()
        }
    }
}
