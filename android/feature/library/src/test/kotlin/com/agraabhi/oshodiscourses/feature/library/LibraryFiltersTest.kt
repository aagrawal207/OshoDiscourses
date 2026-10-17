package com.agraabhi.oshodiscourses.feature.library

import com.agraabhi.oshodiscourses.core.model.LanguageFilter
import com.agraabhi.oshodiscourses.core.testing.FakeCatalogRepository
import com.google.common.truth.Truth.assertThat
import org.junit.Test

class LibraryFiltersTest {
    private val catalog = FakeCatalogRepository(allSeries = LibraryFixtures.all, descriptions = LibraryFixtures.descriptions)
    private val all = LibraryFixtures.all

    @Test
    fun filtersOfferLanguagesDownloadsAndSharedThemes() {
        val filters = LibraryFilters.availableFilters(catalog, all, setOf(LibraryFixtures.bird.id))
        assertThat(filters.map { it.label }).containsExactly(
            "All", "English", "Hindi", "Downloaded", "Awakening", "Beginner Friendly", "Meditation", "Zen",
        ).inOrder()
    }

    @Test
    fun oneVisibleLanguageDropsTheLanguageChipsAndRecountsThemes() {
        val visible = LibraryFilters.visibleSeries(all, LanguageFilter.HINDI)
        val filters = LibraryFilters.availableFilters(catalog, visible, emptySet())
        // meditation: adhyatam + agyat only; "hindi" is never a theme chip.
        assertThat(filters).containsExactly(SeriesFilter.All)
    }

    @Test
    fun sortByNameAndEpisodesBothWays() {
        val byName = LibraryFilters.apply(catalog, all, "", SeriesFilter.All, SortOrder(), emptySet()).map { it.name }
        assertThat(byName).isInOrder()
        val byEpisodesDown = LibraryFilters.apply(catalog, all, "", SeriesFilter.All, SortOrder(SortField.EPISODES, false), emptySet())
        assertThat(byEpisodesDown.map { it.count }).isInOrder(Comparator.reverseOrder<Int>())
    }

    @Test
    fun searchIsCaseInsensitiveOverTheCorpusAndCombinesWithFilters() {
        val zen = LibraryFilters.apply(catalog, all, "ZEN", SeriesFilter.English, SortOrder(), emptySet())
        assertThat(zen.map { it.name }).containsExactly("A Bird on the Wing", "A Sudden Clash of Thunder", "Ah This").inOrder()
        val theme = LibraryFilters.apply(catalog, all, "", SeriesFilter.Theme("meditation"), SortOrder(), emptySet())
        assertThat(theme).hasSize(4)
    }

    @Test
    fun sortOrderToggles() {
        val start = SortOrder()
        assertThat(start.choosing(SortField.NAME)).isEqualTo(SortOrder(SortField.NAME, false))
        assertThat(start.choosing(SortField.NAME).choosing(SortField.EPISODES)).isEqualTo(SortOrder(SortField.EPISODES, true))
        assertThat(SortOrder(SortField.EPISODES, false).accessibilityValue).isEqualTo("Episodes, descending")
    }

    @Test
    fun capitalizedMatchesFoundation() {
        assertThat(LibraryFilters.capitalized("beginner friendly")).isEqualTo("Beginner Friendly")
        assertThat(LibraryFilters.capitalized("self-realization")).isEqualTo("Self-realization")
        assertThat(LibraryFilters.capitalized("osho's TALKS")).isEqualTo("Osho's Talks")
    }
}
