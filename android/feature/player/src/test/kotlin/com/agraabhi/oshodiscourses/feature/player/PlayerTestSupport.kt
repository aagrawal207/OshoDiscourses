package com.agraabhi.oshodiscourses.feature.player

import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import com.agraabhi.oshodiscourses.core.domain.denoise.DenoiseState
import com.agraabhi.oshodiscourses.core.domain.player.PlayerState
import com.agraabhi.oshodiscourses.core.domain.player.QueueItem
import com.agraabhi.oshodiscourses.core.domain.sleep.SleepTimerState
import com.agraabhi.oshodiscourses.core.model.Appearance
import com.agraabhi.oshodiscourses.core.model.Language
import com.agraabhi.oshodiscourses.core.model.SeriesInfo
import com.agraabhi.oshodiscourses.core.model.URLType
import com.agraabhi.oshodiscourses.core.testing.FakeAppServices
import com.agraabhi.oshodiscourses.core.testing.FakeCatalogRepository
import com.agraabhi.oshodiscourses.core.testing.FakeDenoiseController
import com.agraabhi.oshodiscourses.core.testing.FakeDownloadManager
import com.agraabhi.oshodiscourses.core.testing.FakeSleepTimer
import com.agraabhi.oshodiscourses.core.testing.SampleCatalog
import com.agraabhi.oshodiscourses.core.ui.LocalAppServices
import com.agraabhi.oshodiscourses.core.ui.theme.OshoTheme

/** A series whose name wraps, for long-title layouts. */
val LongSeries = SeriesInfo(
    name = "The Book of Secrets: 112 Meditations to Discover the Mystery Within, Volume Two",
    filePrefix = "The_Book_of_Secrets_Vol2_",
    count = 12,
    language = Language.ENGLISH,
    urlType = URLType.UNDERSCORE,
)

fun queueOf(series: SeriesInfo): List<QueueItem> =
    SampleCatalog.discourses(series).map { QueueItem(it.id, "file:///${it.id}.mp3", it.displayTitle, it.seriesName) }

/**
 * Services with "A Bird on the Wing #1" loaded at 8:23 of 1:38:21, the moment in the iOS
 * screenshots, and the whole series queued.
 */
fun playerServices(
    series: SeriesInfo = SampleCatalog.birdOnTheWing,
    index: Int = 0,
    isPlaying: Boolean = true,
    configure: PlayerState.() -> PlayerState = { this },
    sleep: SleepTimerState = SleepTimerState(),
    denoise: DenoiseState = DenoiseState(),
): FakeAppServices {
    val catalog = FakeCatalogRepository(allSeries = SampleCatalog.allSeries + LongSeries)
    val queue = queueOf(series)
    val item = queue[index]
    return FakeAppServices(
        catalog = catalog,
        downloads = FakeDownloadManager(downloaded = queue.map { it.id }.toSet()),
        sleepTimer = FakeSleepTimer(sleep),
        denoise = FakeDenoiseController(denoise),
        initialPlayer = PlayerState(
            currentTrackId = item.id,
            currentTitle = item.title,
            currentSeries = item.series,
            isPlaying = isPlaying,
            currentTime = 503.0,
            duration = 5_901.0,
            queue = queue,
            currentIndex = index,
        ).configure(),
    )
}

@Composable
fun TestHost(
    services: FakeAppServices,
    appearance: Appearance = Appearance.LIGHT,
    fontScale: Float? = null,
    content: @Composable () -> Unit,
) {
    CompositionLocalProvider(LocalAppServices provides services) {
        OshoTheme(appearance = appearance) {
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, fontScale ?: density.fontScale), content = content)
        }
    }
}
