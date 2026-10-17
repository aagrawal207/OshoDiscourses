package com.agraabhi.oshodiscourses.feature.series

import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadError
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadState
import com.agraabhi.oshodiscourses.core.domain.downloads.WaitingReason
import com.agraabhi.oshodiscourses.core.domain.player.PlayerState
import com.agraabhi.oshodiscourses.core.domain.progress.PlaybackProgress
import com.agraabhi.oshodiscourses.core.model.Appearance
import com.agraabhi.oshodiscourses.core.model.Language
import com.agraabhi.oshodiscourses.core.model.SeriesDescription
import com.agraabhi.oshodiscourses.core.model.SeriesInfo
import com.agraabhi.oshodiscourses.core.model.URLType
import com.agraabhi.oshodiscourses.core.testing.FakeAppServices
import com.agraabhi.oshodiscourses.core.testing.FakeCatalogRepository
import com.agraabhi.oshodiscourses.core.testing.FakeDownloadManager
import com.agraabhi.oshodiscourses.core.testing.FakePlaybackStateRepository
import com.agraabhi.oshodiscourses.core.testing.FakeTranscriptRepository
import com.agraabhi.oshodiscourses.core.testing.SampleCatalog
import com.agraabhi.oshodiscourses.core.ui.LocalAppServices
import com.agraabhi.oshodiscourses.core.ui.theme.OshoTheme

/** Series fixtures with every row state on one page. */
object SeriesFixtures {
    val bird = SampleCatalog.birdOnTheWing.copy(count = 9)

    val longTitle = SeriesInfo(
        name = "Vigyan Bhairav Tantra Vol 1: The Book of Secrets and the Hundred and Twelve Meditations",
        filePrefix = "Vigyan_Bhairav_Tantra_Vol_1",
        count = 4,
        language = Language.ENGLISH,
        urlType = URLType.UNDERSCORE,
    )

    val hindi = SampleCatalog.mahaGeeta.copy(count = 6)

    private val descriptions = SampleCatalog.descriptions + (
        longTitle.name to SeriesDescription(
            sourceText = "Shiva answers Devi's questions with one hundred and twelve techniques of meditation. Osho takes each in turn, explaining how it works and who it suits, so that every reader can find a door that opens for them. The talks move between science, love and awareness.",
            year = "1972",
            location = "Mumbai",
            themes = listOf("tantra", "meditation", "techniques", "Shiva", "awareness", "love"),
        )
        )

    fun id(series: SeriesInfo, number: Int) = "${series.id}-$number"

    /** Every row state: playing, completed, downloading, queued, failed, waiting, not downloaded. */
    fun allStates(appearance: Appearance = Appearance.LIGHT): FakeAppServices {
        val s = bird
        val downloads = FakeDownloadManager(downloaded = setOf(id(s, 1), id(s, 2)))
        downloads.setState(id(s, 3), DownloadState.Downloading(0.42, 10_500_000, 25_000_000))
        downloads.setState(id(s, 4), DownloadState.Queued)
        downloads.setState(id(s, 5), DownloadState.Failed(DownloadError.Stalled))
        downloads.setState(id(s, 6), DownloadState.WaitingForWifi)
        downloads.waitingReason.value = WaitingReason.WIFI
        return services(
            series = s,
            downloads = downloads,
            completed = setOf(id(s, 2), id(s, 7)),
            transcripts = (1..6).map { id(s, it) }.toSet(),
            player = PlayerState(currentTrackId = id(s, 1), currentTitle = "A Bird on the Wing - #1", currentSeries = s.name, isPlaying = true),
        )
    }

    fun fresh(series: SeriesInfo, transcripts: Set<String> = emptySet()): FakeAppServices =
        services(series, FakeDownloadManager(), emptySet(), transcripts, PlayerState())

    fun services(
        series: SeriesInfo,
        downloads: FakeDownloadManager,
        completed: Set<String>,
        transcripts: Set<String>,
        player: PlayerState,
    ): FakeAppServices {
        val catalog = FakeCatalogRepository(
            allSeries = listOf(series, SampleCatalog.mahaGeeta).distinctBy { it.id },
            descriptions = descriptions,
            transcriptIDs = transcripts,
        )
        return FakeAppServices(
            catalog = catalog,
            downloads = downloads,
            playbackState = FakePlaybackStateRepository(PlaybackProgress(completedDiscourseIDs = completed)),
            transcripts = FakeTranscriptRepository(availableIDs = transcripts),
            initialPlayer = player,
        )
    }
}

@Composable
fun TestHost(
    services: FakeAppServices,
    appearance: Appearance = Appearance.LIGHT,
    fontScale: Float = 1f,
    content: @Composable () -> Unit,
) {
    val density = LocalDensity.current
    CompositionLocalProvider(
        LocalAppServices provides services,
        LocalDensity provides Density(density.density, fontScale),
    ) {
        OshoTheme(appearance = appearance, content = content)
    }
}
