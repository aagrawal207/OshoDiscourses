package com.agraabhi.oshodiscourses.feature.home

import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import com.agraabhi.oshodiscourses.core.domain.player.PlayerState
import com.agraabhi.oshodiscourses.core.domain.progress.PlaybackProgress
import com.agraabhi.oshodiscourses.core.domain.settings.UserSettings
import com.agraabhi.oshodiscourses.core.model.Appearance
import com.agraabhi.oshodiscourses.core.model.Language
import com.agraabhi.oshodiscourses.core.model.LanguageFilter
import com.agraabhi.oshodiscourses.core.model.SeriesInfo
import com.agraabhi.oshodiscourses.core.model.URLType
import com.agraabhi.oshodiscourses.core.testing.FakeAppServices
import com.agraabhi.oshodiscourses.core.testing.FakeCatalogRepository
import com.agraabhi.oshodiscourses.core.testing.FakeDownloadManager
import com.agraabhi.oshodiscourses.core.testing.FakeEngagementService
import com.agraabhi.oshodiscourses.core.testing.FakePlaybackStateRepository
import com.agraabhi.oshodiscourses.core.testing.FakeSettingsRepository
import com.agraabhi.oshodiscourses.core.testing.SampleCatalog
import com.agraabhi.oshodiscourses.core.ui.LocalAppServices
import com.agraabhi.oshodiscourses.core.ui.theme.OshoTheme

object HomeFixtures {
    private fun english(name: String, prefix: String, count: Int) =
        SeriesInfo(name, prefix, count, Language.ENGLISH, URLType.UNDERSCORE)

    private fun hindi(name: String, prefix: String, count: Int) =
        SeriesInfo(name, prefix, count, Language.HINDI, URLType.OSHO_PREFIX)

    val vbt = english("Vigyan Bhairav Tantra Vol 1", "Vigyan_Bhairav_Tantra_Vol_1", 40)
    val pines = english("Ancient Music In The Pines", "Ancient_Music_In_The_Pines", 9)
    val bird = SampleCatalog.birdOnTheWing.copy(count = 11)
    val mahaGeeta = SampleCatalog.mahaGeeta.copy(count = 18)
    val jeevan = hindi("Jeevan Kranti Ke Sutra", "Jeevan_Kranti_Ke_Sutra", 10)
    val longName = english(
        "The Book of Secrets: The Science of Meditation and the Hundred and Twelve Doors to Your Innermost Core",
        "Book_of_Secrets_Long",
        80,
    )

    val series = listOf(vbt, bird, pines, mahaGeeta, jeevan)

    fun id(series: SeriesInfo, n: Int) = "${series.id}-$n"

    val continueIDs = listOf(id(vbt, 3), id(vbt, 5), id(mahaGeeta, 5), id(jeevan, 2), id(bird, 4))

    fun populated(
        catalogSeries: List<SeriesInfo> = series,
        language: LanguageFilter = LanguageFilter.BOTH,
        allowSupport: Boolean = false,
        recent: List<String> = continueIDs,
        completed: List<String> = listOf(id(mahaGeeta, 4), id(bird, 1)),
    ): FakeAppServices {
        val fractions = listOf(0.76, 0.35, 0.6, 0.12, 0.5)
        val positions = recent.mapIndexed { i, id -> id to 5_400.0 * fractions[i % fractions.size] }.toMap()
        val durations = recent.associateWith { 5_400.0 }
        val first = recent.firstOrNull()
        val entrySeries = first?.let { r -> catalogSeries.first { r.startsWith(it.id) } }
        return FakeAppServices(
            catalog = FakeCatalogRepository(allSeries = catalogSeries),
            downloads = FakeDownloadManager(downloaded = recent.toSet()),
            playbackState = FakePlaybackStateRepository(
                PlaybackProgress(
                    positions = positions,
                    durations = durations,
                    recentlyPlayed = recent,
                    listenedCompleted = completed,
                    completedDiscourseIDs = completed.toSet(),
                ),
            ),
            settings = FakeSettingsRepository(UserSettings(languageFilter = language)),
            engagement = FakeEngagementService(allowSupport = allowSupport),
            initialPlayer = if (first == null) {
                PlayerState()
            } else {
                PlayerState(
                    currentTrackId = first,
                    currentTitle = first,
                    currentSeries = entrySeries?.name.orEmpty(),
                    isPlaying = true,
                    currentTime = 4_100.0,
                    duration = 5_400.0,
                )
            },
        )
    }

    fun newUser(): FakeAppServices = FakeAppServices(catalog = FakeCatalogRepository(allSeries = series))

    fun longTitles(): FakeAppServices {
        val all = listOf(longName, vbt, bird, mahaGeeta)
        return populated(
            catalogSeries = all,
            recent = listOf(id(longName, 12), id(longName, 7)),
            completed = listOf(id(longName, 3)),
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
