package com.agraabhi.oshodiscourses.core.domain

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

/**
 * Every process-wide service (iOS `AppRuntime`). `:app`'s `AppContainer` implements it; feature
 * screens read it through `LocalAppServices` and build their view models from it.
 */
interface AppServices {
    val catalog: CatalogRepository
    val player: PlayerController
    val sleepTimer: SleepTimer
    val downloads: DownloadManager
    val settings: SettingsRepository
    val playbackState: PlaybackStateRepository
    val bookmarks: BookmarkRepository
    val listeningStats: ListeningStatsRepository
    val transcripts: TranscriptRepository
    val transcriptState: TranscriptStateRepository
    val denoise: DenoiseController
    val sync: SyncController
    val support: SupportStore
    val engagement: EngagementService
    val reviewPrompter: ReviewPrompter
}
