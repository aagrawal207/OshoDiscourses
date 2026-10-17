package com.agraabhi.oshodiscourses.core.model

import com.google.common.truth.Truth.assertThat
import kotlin.test.assertNotNull
import org.junit.Test

/** Port of iOS `SeriesMetadataTests`. */
class SeriesMetadataTest {
    private val catalog = CatalogTest.shared

    @Test
    fun popularSeriesHaveDescriptions() {
        for (name in catalog.curatedNames.popularEnglish) assertNotNull(catalog.description(name), name)
    }

    @Test
    fun beginnerSeriesHaveDescriptions() {
        for (name in catalog.curatedNames.beginnerEnglish) assertNotNull(catalog.description(name), name)
    }

    @Test
    fun popularHindiHaveDescriptions() {
        for (name in catalog.curatedNames.popularHindi) assertNotNull(catalog.description(name), name)
    }

    @Test
    fun descriptionCarriesYearPlaceAndThemes() {
        val description = assertNotNull(catalog.description("Ashtavakra Maha Geeta"))
        assertThat(description.year).isEqualTo("1976")
        assertThat(description.location).isEqualTo("Pune")
        assertThat(description.themes).contains("Advaita")
        assertThat(catalog.themes("Ashtavakra Maha Geeta")).isEqualTo(description.themes)
    }

    @Test
    fun searchableTextIncludesThemes() {
        val text = catalog.searchableText("The Mustard Seed")
        assertThat(text).contains("Jesus")
        assertThat(text).contains("Gospel")
    }

    @Test
    fun searchTextIsLowercasedAndBuiltForEverySeries() {
        assertThat(catalog.searchText("The Mustard Seed")).contains("gospel of thomas")
        assertThat(catalog.searchText("Dekh Kabira Roya")).isEqualTo("dekh kabira roya")
    }

    @Test
    fun unknownSeriesReturnsNil() {
        assertThat(catalog.description("Nonexistent Series XYZ")).isNull()
        assertThat(catalog.themes("Nonexistent Series XYZ")).isEmpty()
    }

    @Test
    fun searchableTextForUnknownReturnsSeries() {
        assertThat(catalog.searchableText("Unknown Series")).isEqualTo("Unknown Series")
        assertThat(catalog.searchText("Unknown Series")).isEqualTo("unknown series")
    }

    @Test
    fun discourseSubtitleIncludesPlaceAndYear() {
        assertThat(catalog.discourseSubtitle(1, "Ashtavakra Maha Geeta")).isEqualTo("Discourse 1 · Pune, 1976")
    }

    @Test
    fun discourseSubtitleWithoutMetadataIsJustTheNumber() {
        assertThat(catalog.discourseSubtitle(12, "Nonexistent Series XYZ")).isEqualTo("Discourse 12")
    }

    @Test
    fun discourseSubtitleIsWellFormedForEverySeries() {
        for (series in catalog.allSeries) {
            val subtitle = catalog.discourseSubtitle(3, series.name)
            assertThat(subtitle).startsWith("Discourse 3")
            assertThat(subtitle).doesNotMatch(".*[·,]$")
            assertThat(subtitle).doesNotContain("· ,")
            assertThat(subtitle).doesNotContain(", ·")
        }
    }

    @Test
    fun descriptionsOnlyNameShippedSeries() {
        val names = catalog.allSeries.map { it.name }.toSet()
        val described = names.filter { catalog.description(it) != null }
        assertThat(described).hasSize(32)
    }
}
