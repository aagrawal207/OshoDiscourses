package com.agraabhi.oshodiscourses.playback

import android.content.Context
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.drm.DrmSessionManagerProvider
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy
import androidx.media3.test.utils.ExoPlayerTestRunner
import androidx.media3.test.utils.FakeMediaSource
import androidx.media3.test.utils.FakeTimeline
import androidx.media3.test.utils.TestExoPlayerBuilder
import androidx.media3.test.utils.robolectric.RobolectricUtil
import androidx.media3.test.utils.robolectric.TestPlayerRunHelper
import com.agraabhi.oshodiscourses.core.domain.bookmarks.Bookmark
import com.agraabhi.oshodiscourses.core.domain.player.AudioProcessingStatus
import com.agraabhi.oshodiscourses.core.domain.player.PlayerState
import com.agraabhi.oshodiscourses.core.domain.player.QueueItem
import com.agraabhi.oshodiscourses.core.domain.progress.PlaybackProgress
import com.agraabhi.oshodiscourses.core.domain.settings.UserSettings
import com.agraabhi.oshodiscourses.core.domain.sleep.SleepTimer
import com.agraabhi.oshodiscourses.core.testing.FakeBookmarkRepository
import com.agraabhi.oshodiscourses.core.testing.FakeCatalogRepository
import com.agraabhi.oshodiscourses.core.testing.FakeDownloadManager
import com.agraabhi.oshodiscourses.core.testing.FakeListeningStatsRepository
import com.agraabhi.oshodiscourses.core.testing.FakePlaybackStateRepository
import com.agraabhi.oshodiscourses.core.testing.FakeSettingsRepository
import com.agraabhi.oshodiscourses.core.testing.FakeSleepTimer
import com.agraabhi.oshodiscourses.core.testing.SampleCatalog
import com.agraabhi.oshodiscourses.denoise.DenoiseAudioPipeline
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import java.io.IOException

/** The three sample Bird on the Wing discourses, in series order. */
val BIRD: List<String> = SampleCatalog.discourses(SampleCatalog.birdOnTheWing).map { it.id }

/** No DSP: counts the calls the player makes into the DeNoise seam. */
class RecordingPipeline : DenoiseAudioPipeline {
    var processorRequests = 0
        private set
    var discontinuities = 0
        private set
    override val status = MutableStateFlow<AudioProcessingStatus>(AudioProcessingStatus.Off)

    override fun createAudioProcessors(): List<AudioProcessor> {
        processorRequests++
        return emptyList()
    }

    override fun onDiscontinuity() {
        discontinuities++
    }
}

/**
 * Fake audio by media id: each item gets a timeline of the given duration. Ids in [failing]
 * report a load error until removed, then finish preparing on the next attempt.
 */
class FakeSources(private val durations: Map<String, Double>, val failing: MutableSet<String> = mutableSetOf()) : MediaSource.Factory {
    override fun setDrmSessionManagerProvider(drmSessionManagerProvider: DrmSessionManagerProvider): MediaSource.Factory = this

    override fun setLoadErrorHandlingPolicy(loadErrorHandlingPolicy: LoadErrorHandlingPolicy): MediaSource.Factory = this

    override fun getSupportedTypes(): IntArray = intArrayOf(C.CONTENT_TYPE_OTHER)

    override fun createMediaSource(mediaItem: MediaItem): MediaSource {
        val seconds = durations[mediaItem.mediaId] ?: DEFAULT_DURATION
        val window = FakeTimeline.TimelineWindowDefinition.Builder()
            .setDurationUs((seconds * 1_000_000).toLong())
            .setMediaItem(mediaItem)
            .build()
        val id = mediaItem.mediaId
        return object : FakeMediaSource(FakeTimeline(window), ExoPlayerTestRunner.AUDIO_FORMAT) {
            init {
                if (id in failing) setAllowPreparation(false)
            }

            override fun maybeThrowSourceInfoRefreshError() {
                if (id in failing) throw IOException("unreadable")
                setAllowPreparation(true)
                super.maybeThrowSourceInfoRefreshError()
            }
        }
    }

    companion object {
        const val DEFAULT_DURATION = 600.0
    }
}

class EngineFixture(
    scope: CoroutineScope,
    context: Context,
    downloaded: Set<String> = BIRD.toSet(),
    durations: Map<String, Double> = emptyMap(),
    settings: UserSettings = UserSettings(),
    progress: PlaybackProgress = PlaybackProgress(),
    bookmarks: List<Bookmark> = emptyList(),
    val sleepTimer: SleepTimer = FakeSleepTimer(),
    failing: Set<String> = emptySet(),
) {
    val catalog = FakeCatalogRepository()
    val downloads = FakeDownloadManager(downloaded)
    val bookmarks = FakeBookmarkRepository(bookmarks)
    val settings = FakeSettingsRepository(settings)
    val progress = FakePlaybackStateRepository(progress)
    val stats = FakeListeningStatsRepository()
    val pipeline = RecordingPipeline()
    val sources = FakeSources(durations, failing.toMutableSet())
    val player: ExoPlayer = TestExoPlayerBuilder(context).setMediaSourceFactory(sources).build()
    val engine = PlaybackEngine(
        catalog = catalog,
        downloads = downloads,
        bookmarks = this.bookmarks,
        settings = this.settings,
        playbackState = this.progress,
        listeningStats = stats,
        sleepTimer = sleepTimer,
        pipeline = pipeline,
        scope = scope,
        playerFactory = { player },
    )

    val state: PlayerState get() = engine.state.value

    fun item(id: String): QueueItem = QueueItem(id, downloads.localFileURI(id) ?: "file:///fake/$id.mp3", id, SampleCatalog.birdOnTheWing.name)

    fun runUntil(condition: () -> Boolean) = RobolectricUtil.runMainLooperUntil { condition() }

    fun settle() = TestPlayerRunHelper.advance(player).untilPendingCommandsAreFullyHandled()

    /** Plays the fake clock forward without pausing, unlike `playUntilPosition`. */
    fun playUntil(seconds: Double) = TestPlayerRunHelper.advance(player).untilPositionAtLeast((seconds * 1000).toLong())

    val playerSeconds: Double get() = player.currentPosition / 1000.0
}
