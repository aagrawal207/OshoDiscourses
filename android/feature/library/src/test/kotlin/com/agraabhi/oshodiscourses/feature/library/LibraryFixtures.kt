package com.agraabhi.oshodiscourses.feature.library

import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import com.agraabhi.oshodiscourses.core.domain.settings.UserSettings
import com.agraabhi.oshodiscourses.core.model.Appearance
import com.agraabhi.oshodiscourses.core.model.Language
import com.agraabhi.oshodiscourses.core.model.LanguageFilter
import com.agraabhi.oshodiscourses.core.model.SeriesDescription
import com.agraabhi.oshodiscourses.core.model.SeriesInfo
import com.agraabhi.oshodiscourses.core.model.URLType
import com.agraabhi.oshodiscourses.core.testing.FakeAppServices
import com.agraabhi.oshodiscourses.core.testing.FakeCatalogRepository
import com.agraabhi.oshodiscourses.core.testing.FakeDownloadManager
import com.agraabhi.oshodiscourses.core.testing.FakeSettingsRepository
import com.agraabhi.oshodiscourses.core.ui.LocalAppServices
import com.agraabhi.oshodiscourses.core.ui.theme.OshoTheme

object LibraryFixtures {
    private fun series(name: String, count: Int, language: Language) = SeriesInfo(
        name = name,
        filePrefix = name.replace(' ', '_'),
        count = count,
        language = language,
        urlType = if (language == Language.HINDI) URLType.OSHO_PREFIX else URLType.UNDERSCORE,
    )

    val bird = series("A Bird on the Wing", 11, Language.ENGLISH)
    val thunder = series("A Sudden Clash of Thunder", 10, Language.ENGLISH)
    val adhyatam = series("Adhyatam Upanishad", 17, Language.HINDI)
    val agyat = series("Agyat Ki Aur", 7, Language.HINDI)
    val ahThis = series("Ah This", 8, Language.ENGLISH)
    val ajhun = series("Ajhun Chet Ganwar", 21, Language.HINDI)
    val longName = series("The Book of Secrets: The Science of Meditation and the Hundred and Twelve Doors", 80, Language.ENGLISH)

    val all = listOf(thunder, bird, ajhun, adhyatam, ahThis, agyat, longName)

    private fun d(text: String, vararg themes: String) = SeriesDescription(text, "1975", "Pune", themes.toList())

    val descriptions = mapOf(
        bird.name to d("Eleven Zen stories about awakening.", "Zen", "koans", "awakening", "beginner friendly"),
        thunder.name to d("Ten Zen talks on sudden enlightenment.", "Zen", "awakening", "meditation"),
        adhyatam.name to d("Talks on the Upanishad of the inner self.", "Upanishads", "meditation", "Hindi", "self-realization"),
        agyat.name to d("Towards the unknown.", "meditation", "Hindi", "love"),
        ahThis.name to d("Zen stories told with humour.", "Zen", "humour", "awakening", "beginner friendly"),
        ajhun.name to d("Kabir's songs on waking up.", "Kabir", "devotion", "Hindi", "love", "beginner friendly"),
        longName.name to d("One hundred and twelve meditation techniques.", "tantra", "meditation", "Shiva"),
    )

    fun services(downloaded: Set<String> = emptySet(), language: LanguageFilter = LanguageFilter.BOTH, catalog: List<SeriesInfo> = all) = FakeAppServices(
        catalog = FakeCatalogRepository(allSeries = catalog, descriptions = descriptions),
        downloads = FakeDownloadManager(downloaded = downloaded),
        settings = FakeSettingsRepository(UserSettings(languageFilter = language)),
    )

    fun withDownloads(language: LanguageFilter = LanguageFilter.BOTH) =
        services(downloaded = setOf("${bird.id}-1", "${ajhun.id}-3"), language = language)
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
