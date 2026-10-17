package com.agraabhi.oshodiscourses.feature.library

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadManager
import com.agraabhi.oshodiscourses.core.domain.settings.SettingsRepository
import com.agraabhi.oshodiscourses.core.model.CatalogRepository
import com.agraabhi.oshodiscourses.core.model.Language
import com.agraabhi.oshodiscourses.core.model.LanguageFilter
import com.agraabhi.oshodiscourses.core.model.SeriesInfo
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/** iOS `SeriesFilter`. Theme keys are lowercased; the chip shows them capitalised. */
sealed interface SeriesFilter {
    val label: String

    data object All : SeriesFilter {
        override val label = "All"
    }

    data object English : SeriesFilter {
        override val label = "English"
    }

    data object Hindi : SeriesFilter {
        override val label = "Hindi"
    }

    data object Downloaded : SeriesFilter {
        override val label = "Downloaded"
    }

    data class Theme(val key: String) : SeriesFilter {
        override val label: String get() = LibraryFilters.capitalized(key)
    }
}

enum class SortField(val label: String) { NAME("Name"), EPISODES("Episodes") }

data class SortOrder(val field: SortField = SortField.NAME, val ascending: Boolean = true) {
    /** Tapping the current field flips the direction; a new field starts ascending. */
    fun choosing(next: SortField): SortOrder = if (next == field) copy(ascending = !ascending) else SortOrder(next, true)

    val accessibilityValue: String get() = "${this.field.label}, ${if (ascending) "ascending" else "descending"}"
}

data class LibraryUiState(
    val filters: List<SeriesFilter>,
    val activeFilter: SeriesFilter,
    val sort: SortOrder,
    val series: List<SeriesInfo>,
    val query: String,
) {
    /** iOS shows "No Results" only while searching. */
    val showsNoResults: Boolean get() = series.isEmpty() && query.isNotEmpty()
}

/** The pure rules of iOS `LibraryView`, kept apart so tests can pin them. */
object LibraryFilters {
    /** Themes become chips only when shared by at least this many visible series. */
    const val MIN_SERIES_PER_THEME = 3

    fun visibleSeries(all: List<SeriesInfo>, language: LanguageFilter): List<SeriesInfo> = all.filter {
        !(language.hidesHindi && it.language == Language.HINDI) && !(language.hidesEnglish && it.language == Language.ENGLISH)
    }

    fun downloadedSeriesIDs(catalog: CatalogRepository, downloadedIDs: Set<String>): Set<String> =
        downloadedIDs.mapNotNull { catalog.entry(it)?.series?.id }.toSet()

    fun availableFilters(catalog: CatalogRepository, visible: List<SeriesInfo>, downloadedSeries: Set<String>): List<SeriesFilter> = buildList {
        add(SeriesFilter.All)
        // One visible language makes its chip redundant with All.
        if (visible.any { it.language == Language.ENGLISH } && visible.any { it.language == Language.HINDI }) {
            add(SeriesFilter.English)
            add(SeriesFilter.Hindi)
        }
        if (visible.any { it.id in downloadedSeries }) add(SeriesFilter.Downloaded)
        val counts = mutableMapOf<String, Int>()
        for (series in visible) {
            for (theme in catalog.themes(series.name)) {
                val key = theme.lowercase()
                if (key == "hindi" || key == "english") continue
                counts[key] = (counts[key] ?: 0) + 1
            }
        }
        counts.filterValues { it >= MIN_SERIES_PER_THEME }.keys.sorted().forEach { add(SeriesFilter.Theme(it)) }
    }

    fun apply(
        catalog: CatalogRepository,
        visible: List<SeriesInfo>,
        query: String,
        filter: SeriesFilter,
        sort: SortOrder,
        downloadedSeries: Set<String>,
    ): List<SeriesInfo> {
        var result = visible
        if (query.isNotEmpty()) {
            val needle = query.lowercase()
            result = result.filter { catalog.searchText(it.name).contains(needle) }
        }
        result = when (filter) {
            SeriesFilter.All -> result
            SeriesFilter.English -> result.filter { it.language == Language.ENGLISH }
            SeriesFilter.Hindi -> result.filter { it.language == Language.HINDI }
            SeriesFilter.Downloaded -> result.filter { it.id in downloadedSeries }
            is SeriesFilter.Theme -> result.filter { s -> catalog.themes(s.name).any { it.lowercase() == filter.key } }
        }
        return when (sort.field) {
            SortField.NAME -> if (sort.ascending) result.sortedWith(compareBy { it.name }) else result.sortedWith(compareByDescending { it.name })
            SortField.EPISODES -> if (sort.ascending) result.sortedBy { it.count } else result.sortedByDescending { it.count }
        }
    }

    /** Foundation's `capitalized`: words split on whitespace only, first letter up, rest down. */
    fun capitalized(value: String): String = buildString {
        var startOfWord = true
        for (char in value) {
            if (char.isWhitespace()) {
                startOfWord = true
                append(char)
            } else {
                append(if (startOfWord) char.titlecase() else char.lowercase())
                startOfWord = false
            }
        }
    }
}

/** Library state over the contracts. Filter and sort are not persisted, as on iOS. */
class LibraryViewModel(
    private val catalog: CatalogRepository,
    downloads: DownloadManager,
    settings: SettingsRepository,
) : ViewModel() {
    /** Compose state so the text field updates in the same frame as typing. */
    var query by mutableStateOf("")
        private set

    private val queryFlow = MutableStateFlow("")
    private val filter = MutableStateFlow<SeriesFilter>(SeriesFilter.All)
    private val sort = MutableStateFlow(SortOrder())

    private val language = settings.settings.map { it.languageFilter }.distinctUntilChanged()
    private val downloadedSeries = downloads.downloadedIDs.map { LibraryFilters.downloadedSeriesIDs(catalog, it) }.distinctUntilChanged()

    private val available = combine(language, downloadedSeries) { lang, downloaded ->
        val visible = LibraryFilters.visibleSeries(catalog.allSeries, lang)
        Triple(visible, downloaded, LibraryFilters.availableFilters(catalog, visible, downloaded))
    }

    val state: StateFlow<LibraryUiState> = combine(available, queryFlow, filter, sort) { avail, q, f, s ->
        val (visible, downloaded, filters) = avail
        val active = if (f in filters) f else SeriesFilter.All
        LibraryUiState(filters, active, s, LibraryFilters.apply(catalog, visible, q, active, s, downloaded), q)
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), initial(settings, downloads))

    init {
        // A filter that disappears (language hidden, last download removed) falls back to All for good.
        viewModelScope.launch {
            available.collect { (_, _, filters) -> if (filter.value !in filters) filter.value = SeriesFilter.All }
        }
    }

    private fun initial(settings: SettingsRepository, downloads: DownloadManager): LibraryUiState {
        val visible = LibraryFilters.visibleSeries(catalog.allSeries, settings.settings.value.languageFilter)
        val downloaded = LibraryFilters.downloadedSeriesIDs(catalog, downloads.downloadedIDs.value)
        val filters = LibraryFilters.availableFilters(catalog, visible, downloaded)
        return LibraryUiState(filters, SeriesFilter.All, SortOrder(), LibraryFilters.apply(catalog, visible, "", SeriesFilter.All, SortOrder(), downloaded), "")
    }

    fun updateQuery(value: String) {
        query = value
        queryFlow.value = value
    }

    /** Tapping the active chip returns to All. */
    fun toggleFilter(tapped: SeriesFilter) {
        val active = state.value.activeFilter
        filter.value = if (active == tapped) SeriesFilter.All else tapped
    }

    fun chooseSort(field: SortField) {
        sort.value = sort.value.choosing(field)
    }

    fun coverURL(seriesID: String): String? = catalog.coverURL(seriesID)
}
