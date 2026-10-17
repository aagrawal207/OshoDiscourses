package com.agraabhi.oshodiscourses.feature.downloads

import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.junit4.ComposeContentTestRule
import androidx.compose.ui.unit.Density
import com.agraabhi.oshodiscourses.core.domain.bookmarks.Bookmark
import com.agraabhi.oshodiscourses.core.domain.bookmarks.BookmarkCategory
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadState
import com.agraabhi.oshodiscourses.core.domain.downloads.WaitingReason
import com.agraabhi.oshodiscourses.core.domain.player.PlayerState
import com.agraabhi.oshodiscourses.core.domain.progress.PlaybackProgress
import com.agraabhi.oshodiscourses.core.domain.stats.DailyListening
import com.agraabhi.oshodiscourses.core.domain.stats.ListeningStats
import com.agraabhi.oshodiscourses.core.model.Appearance
import com.agraabhi.oshodiscourses.core.testing.FakeAppServices
import com.agraabhi.oshodiscourses.core.testing.FakeBookmarkRepository
import com.agraabhi.oshodiscourses.core.testing.FakeClock
import com.agraabhi.oshodiscourses.core.testing.FakeDownloadManager
import com.agraabhi.oshodiscourses.core.testing.FakeListeningStatsRepository
import com.agraabhi.oshodiscourses.core.testing.FakePlaybackStateRepository
import com.agraabhi.oshodiscourses.core.testing.SampleCatalog
import com.agraabhi.oshodiscourses.core.ui.LocalAppServices
import com.agraabhi.oshodiscourses.core.ui.theme.OshoTheme
import java.time.LocalDate

/** Shared fixtures for the Downloads, Bookmarks and Stats tests. */
internal object Fixtures {
    val bird = SampleCatalog.discourses(SampleCatalog.birdOnTheWing)
    val geeta = SampleCatalog.discourses(SampleCatalog.mahaGeeta)

    /** A fixed "today" so day labels in screenshots never drift. */
    val today: LocalDate = LocalDate.of(2026, 7, 31)

    fun bookmarks(clock: FakeClock): List<Bookmark> = listOf(
        Bookmark("b1", geeta[0].id, geeta[0].seriesName, geeta[0].displayTitle, 0.0, "Don't be a soldier", BookmarkCategory.RELISTEN, createdAt = clock.nowMillis - 1_000),
        Bookmark("b2", geeta[1].id, geeta[1].seriesName, geeta[1].displayTitle, 1_800.0, "Demonetization predicted", BookmarkCategory.FUNNY, createdAt = clock.nowMillis - 2_000),
        Bookmark("b3", geeta[1].id, geeta[1].seriesName, geeta[1].displayTitle, 4_441.0, "", BookmarkCategory.PROFOUND, createdAt = clock.nowMillis - 3_000),
        Bookmark("b4", bird[0].id, bird[0].seriesName, bird[0].displayTitle, 2_051.0, "Muslim Atheist", BookmarkCategory.CUSTOM, "Knowledge", clock.nowMillis - 4_000),
        Bookmark("b5", bird[2].id, bird[2].seriesName, bird[2].displayTitle, 1_963.0, "Atheist love Osho", BookmarkCategory.AWESOME, createdAt = clock.nowMillis - 5_000),
    )

    val stats = ListeningStats(
        totalToday = 17 * 60.0,
        totalLastWeek = 2 * 3600.0 + 54 * 60,
        totalLastMonth = 13 * 3600.0 + 32 * 60,
        totalAllTime = 18 * 3600.0 + 55 * 60,
        streakDays = 4,
        distinctActiveDays = 12,
        dailyHistory = listOf(15, 36, 49, 32, 34, 15, 50, 47, 13, 15, 17).mapIndexed { i, minutes ->
            DailyListening(today.minusDays((10 - i).toLong()).toString(), minutes * 60.0)
        },
    )

    /** Two series on disk, one talk downloading, one removed earlier, one playing. */
    fun populated(
        waiting: WaitingReason? = null,
        playing: Boolean = true,
    ): FakeAppServices {
        val clock = FakeClock()
        val downloads = FakeDownloadManager(downloaded = setOf(bird[0].id, bird[1].id, geeta[0].id), bytesPerFile = 36_500_000)
        downloads.downloadHistory.value = downloads.downloadHistory.value + bird[2].id
        val activeState = when (waiting) {
            WaitingReason.WIFI -> DownloadState.WaitingForWifi
            WaitingReason.CONNECTION -> DownloadState.WaitingForConnection
            null -> DownloadState.Downloading(0.42, 12_000_000, 28_000_000)
        }
        downloads.setState(geeta[1].id, activeState)
        downloads.waitingReason.value = waiting
        return FakeAppServices(
            clock = clock,
            downloads = downloads,
            bookmarks = FakeBookmarkRepository(bookmarks(clock), clock),
            listeningStats = FakeListeningStatsRepository(stats),
            playbackState = FakePlaybackStateRepository(
                PlaybackProgress(
                    positions = mapOf(bird[0].id to 754.0, geeta[0].id to 2_100.0),
                    recentlyPlayed = listOf(bird[0].id, geeta[0].id, bird[1].id),
                    completedDiscourseIDs = setOf(bird[1].id) + geeta.map { it.id },
                    allPlayedDiscourseIDs = listOf(bird[0].id, geeta[0].id, bird[1].id, geeta[1].id),
                ),
                clock,
            ),
            initialPlayer = PlayerState(
                currentTrackId = bird[0].id,
                currentTitle = bird[0].displayTitle,
                currentSeries = bird[0].seriesName,
                isPlaying = playing,
                currentTime = 754.0,
                duration = 5_400.0,
            ),
        )
    }

    fun empty(): FakeAppServices = FakeAppServices()
}

internal fun ComposeContentTestRule.show(
    services: FakeAppServices,
    appearance: Appearance = Appearance.LIGHT,
    fontScale: Float = 1f,
    content: @Composable () -> Unit,
) {
    setContent {
        CompositionLocalProvider(LocalAppServices provides services) {
            OshoTheme(appearance = appearance, accent = services.settings.settings.value.effectiveAccentTheme) {
                val density = LocalDensity.current
                CompositionLocalProvider(LocalDensity provides Density(density.density, fontScale), content = content)
            }
        }
    }
}
