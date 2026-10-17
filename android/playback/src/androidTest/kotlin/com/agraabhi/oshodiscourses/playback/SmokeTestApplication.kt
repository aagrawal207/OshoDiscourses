package com.agraabhi.oshodiscourses.playback

import android.app.Application
import androidx.media3.common.audio.AudioProcessor
import com.agraabhi.oshodiscourses.core.domain.player.AudioProcessingStatus
import com.agraabhi.oshodiscourses.core.testing.FakeBookmarkRepository
import com.agraabhi.oshodiscourses.core.testing.FakeCatalogRepository
import com.agraabhi.oshodiscourses.core.testing.FakeDownloadManager
import com.agraabhi.oshodiscourses.core.testing.FakeListeningStatsRepository
import com.agraabhi.oshodiscourses.core.testing.FakePlaybackStateRepository
import com.agraabhi.oshodiscourses.core.testing.FakeSettingsRepository
import com.agraabhi.oshodiscourses.denoise.DenoiseAudioPipeline
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** Hosts a production engine over in-memory repositories, so the real service can find it. */
class SmokeTestApplication : Application(), PlaybackEngineProvider {
    val sleepTimer by lazy { SleepTimerService(MainScope()) }

    override val playbackEngine: PlaybackEngine by lazy {
        PlaybackEngine.create(
            context = this,
            catalog = FakeCatalogRepository(),
            downloads = FakeDownloadManager(),
            bookmarks = FakeBookmarkRepository(),
            settings = FakeSettingsRepository(),
            playbackState = FakePlaybackStateRepository(),
            listeningStats = FakeListeningStatsRepository(),
            sleepTimer = sleepTimer,
            pipeline = PassthroughPipeline,
        ).also { engine -> sleepTimer.onExpire = { engine.setPlaying(false) } }
    }
}

/** No DSP until `:denoise` ships its chain. */
object PassthroughPipeline : DenoiseAudioPipeline {
    override fun createAudioProcessors(): List<AudioProcessor> = emptyList()

    override fun onDiscontinuity() = Unit

    override val status: StateFlow<AudioProcessingStatus> = MutableStateFlow(AudioProcessingStatus.Off)
}
