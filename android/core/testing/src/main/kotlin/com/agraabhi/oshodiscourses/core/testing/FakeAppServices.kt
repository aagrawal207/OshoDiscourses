package com.agraabhi.oshodiscourses.core.testing

import com.agraabhi.oshodiscourses.core.domain.AppServices
import com.agraabhi.oshodiscourses.core.domain.player.PlayerState
import com.agraabhi.oshodiscourses.core.domain.settings.UserSettings

/** Every contract backed by its fake, wired to each other the way the app wires the real ones. */
class FakeAppServices(
    val clock: FakeClock = FakeClock(),
    override val catalog: FakeCatalogRepository = FakeCatalogRepository(),
    override val downloads: FakeDownloadManager = FakeDownloadManager(),
    override val bookmarks: FakeBookmarkRepository = FakeBookmarkRepository(clock = clock),
    override val settings: FakeSettingsRepository = FakeSettingsRepository(),
    override val playbackState: FakePlaybackStateRepository = FakePlaybackStateRepository(clock = clock),
    override val listeningStats: FakeListeningStatsRepository = FakeListeningStatsRepository(),
    override val transcripts: FakeTranscriptRepository = FakeTranscriptRepository(),
    override val transcriptState: FakeTranscriptStateRepository = FakeTranscriptStateRepository(clock = clock),
    override val sleepTimer: FakeSleepTimer = FakeSleepTimer(),
    override val denoise: FakeDenoiseController = FakeDenoiseController(),
    override val sync: FakeSyncController = FakeSyncController(clock = clock),
    override val support: FakeSupportStore = FakeSupportStore(),
    override val engagement: FakeEngagementService = FakeEngagementService(),
    override val reviewPrompter: FakeReviewPrompter = FakeReviewPrompter(),
    initialPlayer: PlayerState = PlayerState(),
) : AppServices {
    override val player: FakePlayerController = FakePlayerController(catalog, downloads, bookmarks, initialPlayer)

    companion object {
        /** A populated state for previews: two downloads, one discourse playing, some progress. */
        fun preview(settings: UserSettings = UserSettings()): FakeAppServices {
            val first = SampleCatalog.firstDiscourse
            val services = FakeAppServices(
                downloads = FakeDownloadManager(downloaded = setOf(first.id, SampleCatalog.hindiDiscourse.id)),
                settings = FakeSettingsRepository(settings),
                initialPlayer = PlayerState(
                    currentTrackId = first.id,
                    currentTitle = first.displayTitle,
                    currentSeries = first.seriesName,
                    currentTime = 754.0,
                    duration = 5_400.0,
                ),
            )
            return services
        }
    }
}
