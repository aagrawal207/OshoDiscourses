package com.agraabhi.oshodiscourses

import android.app.Application
import android.os.SystemClock
import android.util.Log
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import com.agraabhi.oshodiscourses.billing.PlaySupportStore
import com.agraabhi.oshodiscourses.billing.engagement.LocalEngagementService
import com.agraabhi.oshodiscourses.billing.engagement.PlayReviewPrompter
import com.agraabhi.oshodiscourses.core.data.DataRepositories
import com.agraabhi.oshodiscourses.core.domain.AppServices
import com.agraabhi.oshodiscourses.core.domain.bookmarks.BookmarkRepository
import com.agraabhi.oshodiscourses.core.domain.denoise.DenoiseController
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadManager
import com.agraabhi.oshodiscourses.core.domain.engagement.EngagementService
import com.agraabhi.oshodiscourses.core.domain.engagement.ReviewPrompter
import com.agraabhi.oshodiscourses.core.domain.player.PlayerController
import com.agraabhi.oshodiscourses.core.domain.progress.PlaybackStateRepository
import com.agraabhi.oshodiscourses.core.domain.settings.SettingsRepository
import com.agraabhi.oshodiscourses.core.domain.sleep.SleepTimer
import com.agraabhi.oshodiscourses.core.domain.stats.ListeningStatsRepository
import com.agraabhi.oshodiscourses.core.domain.support.SupportStore
import com.agraabhi.oshodiscourses.core.domain.sync.SyncController
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptRepository
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptStateRepository
import com.agraabhi.oshodiscourses.core.model.BundledCatalogRepository
import com.agraabhi.oshodiscourses.core.model.CatalogRepository
import com.agraabhi.oshodiscourses.denoise.DenoiseEngine
import com.agraabhi.oshodiscourses.downloads.DownloadEngine
import com.agraabhi.oshodiscourses.downloads.Downloads
import com.agraabhi.oshodiscourses.playback.PlaybackEngine
import com.agraabhi.oshodiscourses.playback.SleepTimerService
import com.agraabhi.oshodiscourses.sync.DriveSync
import com.agraabhi.oshodiscourses.transcript.Transcripts
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import java.util.concurrent.TimeUnit

/**
 * The process-wide service graph (iOS `AppRuntime`), created once in [OshoApplication] so the
 * activity, media service, download job and sync worker share one instance of every service.
 * Construction order matters: repositories, catalog and transcripts feed downloads, which feed
 * playback; the review prompter reads the player lazily because it exists first.
 */
class AppContainer(private val application: Application) : AppServices {
    /** Repository work and collectors; never the main thread. */
    val appScope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    /** The player and sleep timer keep their state on the main thread. */
    private val mainScope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    /** One connection pool for downloads, transcripts and Drive; each adds its own timeouts. */
    val httpClient: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .build()

    val activityTracker = ForegroundActivityTracker(application)

    // A second instance over the same files breaks DataStore, so this is the only one.
    private val data = DataRepositories(application, appScope)

    private val bundledCatalog = BundledCatalogRepository()
    override val catalog: CatalogRepository = bundledCatalog

    override val settings: SettingsRepository = data.settings
    override val playbackState: PlaybackStateRepository = data.playbackState
    override val bookmarks: BookmarkRepository = data.bookmarks
    override val listeningStats: ListeningStatsRepository = data.listeningStats
    override val transcriptState: TranscriptStateRepository = data.transcriptState

    override val transcripts: TranscriptRepository =
        Transcripts.create(application, httpClient, catalog = lazy { bundledCatalog.transcriptCatalog })

    val downloadEngine: DownloadEngine = Downloads.createEngine(application, catalog, settings, transcripts, appScope, httpClient)

    private val notificationPrompt = NotificationPermissionPrompt(application, activityTracker::current)
    override val downloads: DownloadManager = PromptingDownloadManager(downloadEngine, notificationPrompt)

    private val denoiseEngine: DenoiseEngine = DenoiseEngine.create(application, settings, appScope)
    override val denoise: DenoiseController = denoiseEngine

    private val sleepTimerService = SleepTimerService(mainScope)
    override val sleepTimer: SleepTimer = sleepTimerService

    override val engagement: EngagementService = LocalEngagementService(application)

    override val reviewPrompter: ReviewPrompter = PlayReviewPrompter(
        context = application,
        activityProvider = activityTracker::current,
        scope = appScope,
        engagement = engagement,
        listeningStats = listeningStats,
        sleepTimer = sleepTimer,
        isPlaying = { playbackEngine.state.value.isPlaying },
    )

    // Smart Download runs from the engine, so it uses the engine directly and never prompts.
    val playbackEngine: PlaybackEngine = PlaybackEngine.create(
        context = application,
        catalog = catalog,
        downloads = downloadEngine,
        bookmarks = bookmarks,
        settings = settings,
        playbackState = playbackState,
        listeningStats = listeningStats,
        sleepTimer = sleepTimer,
        pipeline = denoiseEngine,
        reviewPrompter = reviewPrompter,
        scope = mainScope,
    )
    override val player: PlayerController = playbackEngine

    private val supportStore = PlaySupportStore(
        context = application,
        activityProvider = activityTracker::current,
        scope = appScope,
        licenseKey = BuildConfig.PLAY_LICENSE_KEY.ifBlank { null },
    )
    override val support: SupportStore = supportStore

    private val snapshotCoordinator = data.cloudSnapshotCoordinator(downloadEngine)

    override val sync: SyncController = DriveSync.create(
        context = application,
        store = CoordinatorSnapshotStore(snapshotCoordinator),
        // Progress, bookmark and transcript edits (never merges), plus download history, which the coordinator leaves out.
        localChanges = merge(snapshotCoordinator.localChanges, downloadEngine.downloadHistory.drop(1).map { }),
        activityProvider = activityTracker::current,
        httpClient = httpClient,
        codec = IosSnapshotCodec,
    )

    /** Background start-up work and lifecycle hooks; call once, right after construction. */
    fun start() {
        sleepTimerService.onExpire = { playbackEngine.setPlaying(false) }

        mainScope.launch {
            playbackEngine.state
                .map { Triple(it.hasTrack, it.isPlaying && !it.isBuffering, it.error != null) }
                .distinctUntilChanged()
                .collect { (hasTrack, playing, failed) -> denoiseEngine.onPlaybackChanged(hasTrack, playing, failed) }
        }

        appScope.launch {
            val started = SystemClock.elapsedRealtime()
            withContext(Dispatchers.IO) { bundledCatalog.warmUp() }
            Log.i(TAG, "outcome=catalog_warm ms=${SystemClock.elapsedRealtime() - started}")
            downloadEngine.awaitReady()
            // Shows the last talk in the mini-player, paused, as iOS does at launch.
            playbackEngine.restoreLastSession()
        }

        appScope.launch { runCatching { sync.start() }.onFailure { if (it is CancellationException) throw it; Log.w(TAG, "sync start failed", it) } }

        appScope.launch {
            delay(TRANSCRIPT_BACKFILL_DELAY_MS)
            downloadEngine.awaitReady()
            transcripts.backfill(downloadEngine.downloadedIDs.value.toList(), settings.settings.value.allowCellularDownloads)
        }

        ProcessLifecycleOwner.get().lifecycle.addObserver(
            object : DefaultLifecycleObserver {
                override fun onStart(owner: LifecycleOwner) {
                    appScope.launch {
                        // The daily accent and "today" can roll over while the app sits in the background.
                        settings.refreshShuffledTheme()
                        data.listeningStats.refresh()
                    }
                    // Play has no renewal stream; foregrounding is when status and approved tips catch up.
                    appScope.launch { supportStore.recoverPurchases() }
                }

                override fun onStop(owner: LifecycleOwner) {
                    appScope.launch { data.transcriptState.flush() }
                }
            },
        )
    }

    private companion object {
        const val TAG = "AppContainer"

        /** iOS waits so the backfill never competes with launch; one fetch at a time after that. */
        const val TRANSCRIPT_BACKFILL_DELAY_MS = 5_000L
    }
}
