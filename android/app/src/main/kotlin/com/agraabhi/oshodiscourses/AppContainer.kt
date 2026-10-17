package com.agraabhi.oshodiscourses

import android.content.Context
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
import com.agraabhi.oshodiscourses.core.model.CatalogRepository
import com.agraabhi.oshodiscourses.core.testing.FakeAppServices

/**
 * Manual dependency graph (iOS `AppRuntime`), created once in [OshoApplication]. Every service
 * is a fake until its implementation task lands; swap one line per service.
 */
class AppContainer(@Suppress("unused") private val context: Context) : AppServices {
    private val fakes = FakeAppServices()

    override val catalog: CatalogRepository = fakes.catalog
    override val settings: SettingsRepository = fakes.settings
    override val playbackState: PlaybackStateRepository = fakes.playbackState
    override val bookmarks: BookmarkRepository = fakes.bookmarks
    override val listeningStats: ListeningStatsRepository = fakes.listeningStats
    override val transcriptState: TranscriptStateRepository = fakes.transcriptState
    override val downloads: DownloadManager = fakes.downloads
    override val transcripts: TranscriptRepository = fakes.transcripts
    override val sleepTimer: SleepTimer = fakes.sleepTimer
    override val player: PlayerController = fakes.player
    override val denoise: DenoiseController = fakes.denoise
    override val sync: SyncController = fakes.sync
    override val support: SupportStore = fakes.support
    override val engagement: EngagementService = fakes.engagement
    override val reviewPrompter: ReviewPrompter = fakes.reviewPrompter
}
