package com.agraabhi.oshodiscourses.core.model

import com.google.common.truth.Truth.assertThat
import org.junit.Test

/** The `LibraryView` list rules, over a small hand-built catalog with known themes. */
class LibraryFiltersTest {
    private fun series(name: String, count: Int, language: Language) =
        SeriesInfo(name, name.replace(' ', '_'), count, language, URLType.OSHO_PREFIX)

    private val zenA = series("Zen A", 10, Language.ENGLISH)
    private val zenB = series("Zen B", 30, Language.ENGLISH)
    private val zenC = series("zen c", 20, Language.HINDI)
    private val plain = series("Plain", 20, Language.HINDI)
    private val all = listOf(zenA, zenB, zenC, plain)

    private val themeMap = mapOf(
        "Zen A" to listOf("Zen", "Love", "Hindi"),
        "Zen B" to listOf("zen", "Love", "English"),
        "zen c" to listOf("ZEN", "Love", "Hindi", "Tao Te Ching"),
    )

    private val catalog = object : CatalogRepository by CatalogTest.shared {
        override val allSeries = all
        override fun entry(discourseID: String): CatalogEntry? {
            val s = all.firstOrNull { discourseID.startsWith("${it.id}-") } ?: return null
            return CatalogEntry(CatalogDiscourse(discourseID, s.name, 1, "", s.language), s)
        }
        override fun description(seriesName: String): SeriesDescription? =
            themeMap[seriesName]?.let { SeriesDescription("About $seriesName", null, null, it) }
        // Delegation forwards default members too, so themes must be overridden alongside description.
        override fun themes(seriesName: String): List<String> = themeMap[seriesName].orEmpty()
        override fun searchText(seriesName: String): String =
            (seriesName + " " + themeMap[seriesName].orEmpty().joinToString(" ")).lowercase()
    }

    @Test
    fun visibleSeriesFollowsLanguageFilter() {
        assertThat(LibraryFilters.visibleSeries(all, LanguageFilter.BOTH)).isEqualTo(all)
        assertThat(LibraryFilters.visibleSeries(all, LanguageFilter.ENGLISH)).containsExactly(zenA, zenB).inOrder()
        assertThat(LibraryFilters.visibleSeries(all, LanguageFilter.HINDI)).containsExactly(zenC, plain).inOrder()
    }

    @Test
    fun availableFiltersOfferSharedThemesAfterLanguageAndDownloads() {
        val downloaded = LibraryFilters.downloadedSeriesIDs(listOf("${plain.id}-3", "gone-1"), catalog)
        assertThat(downloaded).containsExactly(plain.id)
        assertThat(LibraryFilters.availableFilters(all, downloaded, catalog)).containsExactly(
            SeriesFilter.All,
            SeriesFilter.English,
            SeriesFilter.Hindi,
            SeriesFilter.Downloaded,
            SeriesFilter.Theme("love"),
            SeriesFilter.Theme("zen"),
        ).inOrder()
    }

    @Test
    fun singleLanguageHidesLanguageChipsAndRareThemes() {
        val visible = listOf(zenA, zenB)
        assertThat(LibraryFilters.availableFilters(visible, setOf(plain.id), catalog)).containsExactly(SeriesFilter.All)
    }

    @Test
    fun searchMatchesNameOrThemeCaseInsensitively() {
        val result = LibraryFilters.filteredSeries(
            all, "TAO", SeriesFilter.All, SeriesSortField.NAME, SortDirection.ASCENDING, emptySet(), catalog,
        )
        assertThat(result).containsExactly(zenC)
    }

    @Test
    fun themeFilterMatchesLowercasedTheme() {
        val result = LibraryFilters.filteredSeries(
            all, "", SeriesFilter.Theme("zen"), SeriesSortField.NAME, SortDirection.ASCENDING, emptySet(), catalog,
        )
        // Ordinal ordering puts upper-case names before lower-case ones, as Swift's String `<` does.
        assertThat(result).containsExactly(zenA, zenB, zenC).inOrder()
    }

    @Test
    fun episodesSortIsStableInBothDirections() {
        val ascending = LibraryFilters.filteredSeries(
            all, "", SeriesFilter.All, SeriesSortField.EPISODES, SortDirection.ASCENDING, emptySet(), catalog,
        )
        assertThat(ascending).containsExactly(zenA, zenC, plain, zenB).inOrder()
        val descending = LibraryFilters.filteredSeries(
            all, "", SeriesFilter.All, SeriesSortField.EPISODES, SortDirection.DESCENDING, emptySet(), catalog,
        )
        assertThat(descending).containsExactly(zenB, zenC, plain, zenA).inOrder()
    }

    @Test
    fun languageAndDownloadedFilters() {
        val hindi = LibraryFilters.filteredSeries(
            all, "", SeriesFilter.Hindi, SeriesSortField.NAME, SortDirection.DESCENDING, emptySet(), catalog,
        )
        assertThat(hindi).containsExactly(zenC, plain).inOrder()
        val downloaded = LibraryFilters.filteredSeries(
            all, "", SeriesFilter.Downloaded, SeriesSortField.NAME, SortDirection.ASCENDING, setOf(zenB.id), catalog,
        )
        assertThat(downloaded).containsExactly(zenB)
    }

    @Test
    fun chipLabelsAndSortToggle() {
        assertThat(SeriesFilter.Theme("self-realization").label).isEqualTo("Self-Realization")
        assertThat(SeriesFilter.Theme("osho's way").label).isEqualTo("Osho's Way")
        assertThat(SeriesFilter.Downloaded.label).isEqualTo("Downloaded")
        assertThat(SortDirection.ASCENDING.toggled()).isEqualTo(SortDirection.DESCENDING)
        assertThat(SeriesSortField.EPISODES.label).isEqualTo("Episodes")
    }

    @Test
    fun realCatalogOffersThemeChips() {
        val real = CatalogTest.shared
        val filters = LibraryFilters.availableFilters(real.allSeries, emptySet(), real)
        assertThat(filters.take(3)).containsExactly(SeriesFilter.All, SeriesFilter.English, SeriesFilter.Hindi).inOrder()
        assertThat(filters).contains(SeriesFilter.Theme("meditation"))
        assertThat(filters).doesNotContain(SeriesFilter.Downloaded)
        assertThat(filters).doesNotContain(SeriesFilter.Theme("hindi"))
    }
}
