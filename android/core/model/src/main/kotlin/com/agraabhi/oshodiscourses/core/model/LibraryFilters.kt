package com.agraabhi.oshodiscourses.core.model

/** A Library filter chip (iOS `SeriesFilter`). Themes are keyed by their lowercased name. */
sealed interface SeriesFilter {
    val label: String

    data object All : SeriesFilter {
        override val label: String = "All"
    }

    data object English : SeriesFilter {
        override val label: String = "English"
    }

    data object Hindi : SeriesFilter {
        override val label: String = "Hindi"
    }

    data object Downloaded : SeriesFilter {
        override val label: String = "Downloaded"
    }

    data class Theme(val name: String) : SeriesFilter {
        override val label: String get() = capitalizedWords(name)
    }
}

/** iOS `SeriesSortField`; [label] is the menu text. */
enum class SeriesSortField(val label: String) {
    NAME("Name"),
    EPISODES("Episodes"),
}

/** iOS `SortDirection`. */
enum class SortDirection {
    ASCENDING,
    DESCENDING,
    ;

    fun toggled(): SortDirection = if (this == ASCENDING) DESCENDING else ASCENDING
}

/** The Library list rules from iOS `LibraryView`: visibility, chips, search, filter and sort. */
object LibraryFilters {
    /** A theme becomes a chip only when this many visible series share it. */
    const val MIN_SERIES_PER_THEME_FILTER: Int = 3

    fun visibleSeries(allSeries: List<SeriesInfo>, languageFilter: LanguageFilter): List<SeriesInfo> =
        allSeries.filter { series ->
            !(languageFilter.hidesHindi && series.language == Language.HINDI) &&
                !(languageFilter.hidesEnglish && series.language == Language.ENGLISH)
        }

    /** Series that own at least one downloaded discourse; ids the catalog no longer has are skipped. */
    fun downloadedSeriesIDs(downloadedDiscourseIDs: Collection<String>, catalog: CatalogRepository): Set<String> =
        downloadedDiscourseIDs.mapNotNullTo(HashSet()) { catalog.entry(it)?.series?.id }

    /**
     * "All" always; English and Hindi only when both are visible; Downloaded when a visible series
     * has a download; then shared themes in sorted order. Language themes duplicate the chips.
     */
    fun availableFilters(
        visibleSeries: List<SeriesInfo>,
        downloadedSeriesIDs: Set<String>,
        catalog: CatalogRepository,
    ): List<SeriesFilter> {
        val filters = mutableListOf<SeriesFilter>(SeriesFilter.All)
        val hasEnglish = visibleSeries.any { it.language == Language.ENGLISH }
        val hasHindi = visibleSeries.any { it.language == Language.HINDI }
        if (hasEnglish && hasHindi) {
            filters += SeriesFilter.English
            filters += SeriesFilter.Hindi
        }
        if (visibleSeries.any { it.id in downloadedSeriesIDs }) filters += SeriesFilter.Downloaded

        val themeCounts = HashMap<String, Int>()
        for (series in visibleSeries) {
            for (theme in catalog.themes(series.name)) {
                val key = theme.lowercase()
                if (key == "hindi" || key == "english") continue
                themeCounts[key] = (themeCounts[key] ?: 0) + 1
            }
        }
        themeCounts.filterValues { it >= MIN_SERIES_PER_THEME_FILTER }.keys.sorted()
            .mapTo(filters) { SeriesFilter.Theme(it) }
        return filters
    }

    /** Search matches the lowercased name, description and themes; then filter, then sort. */
    fun filteredSeries(
        visibleSeries: List<SeriesInfo>,
        searchText: String,
        filter: SeriesFilter,
        sortField: SeriesSortField,
        sortDirection: SortDirection,
        downloadedSeriesIDs: Set<String>,
        catalog: CatalogRepository,
    ): List<SeriesInfo> {
        var result = visibleSeries
        if (searchText.isNotEmpty()) {
            val query = searchText.lowercase()
            result = result.filter { catalog.searchText(it.name).contains(query) }
        }
        result = when (filter) {
            SeriesFilter.All -> result
            SeriesFilter.English -> result.filter { it.language == Language.ENGLISH }
            SeriesFilter.Hindi -> result.filter { it.language == Language.HINDI }
            SeriesFilter.Downloaded -> result.filter { it.id in downloadedSeriesIDs }
            is SeriesFilter.Theme -> result.filter { series ->
                catalog.themes(series.name).any { it.lowercase() == filter.name }
            }
        }
        val comparator: Comparator<SeriesInfo> = when (sortField) {
            SeriesSortField.NAME -> compareBy { it.name }
            SeriesSortField.EPISODES -> compareBy { it.count }
        }
        return result.sortedWith(if (sortDirection == SortDirection.ASCENDING) comparator else comparator.reversed())
    }
}

/**
 * Foundation's `String.capitalized`: every word starts upper-case and the rest is lower-case.
 * Hyphens and spaces start words; apostrophes do not ("osho's" becomes "Osho's").
 */
fun capitalizedWords(value: String): String {
    val out = StringBuilder(value.length)
    var previous: Char? = null
    for (c in value) {
        val startsWord = previous == null || !(previous.isLetterOrDigit() || previous == '\'' || previous == '’')
        out.append(if (startsWord) c.uppercaseChar() else c.lowercaseChar())
        previous = c
    }
    return out.toString()
}
