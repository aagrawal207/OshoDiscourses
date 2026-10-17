package com.agraabhi.oshodiscourses.feature.home

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadManager
import com.agraabhi.oshodiscourses.core.domain.player.PlayerController
import com.agraabhi.oshodiscourses.core.domain.player.PlayerState
import com.agraabhi.oshodiscourses.core.domain.progress.ContinueListening
import com.agraabhi.oshodiscourses.core.domain.progress.PlaybackProgress
import com.agraabhi.oshodiscourses.core.domain.progress.PlaybackStateRepository
import com.agraabhi.oshodiscourses.core.domain.settings.SettingsRepository
import com.agraabhi.oshodiscourses.core.model.CatalogDiscourse
import com.agraabhi.oshodiscourses.core.model.CatalogRepository
import com.agraabhi.oshodiscourses.core.model.LanguageFilter
import com.agraabhi.oshodiscourses.core.model.SeriesInfo
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/** A Continue Listening discourse with its saved progress (the live values come from the player). */
data class ContinueItem(
    val discourse: CatalogDiscourse,
    val series: SeriesInfo,
    val position: Double,
    val savedDuration: Double,
) {
    val id: String get() = discourse.id
}

data class ContinueGroup(val series: SeriesInfo, val items: List<ContinueItem>)

data class CompletedItem(val discourse: CatalogDiscourse, val series: SeriesInfo) {
    val id: String get() = discourse.id
}

data class Shelf(val title: String, val series: List<SeriesInfo>)

data class HomeUiState(
    /** Up to [HomeContent.CONTINUE_COUNTED] items; Clear All dismisses all of them. */
    val continueListening: List<ContinueItem> = emptyList(),
    /** The first [HomeContent.CONTINUE_SHOWN], grouped by series in first-appearance order. */
    val continueGroups: List<ContinueGroup> = emptyList(),
    val recentlyCompleted: List<CompletedItem> = emptyList(),
    val shelves: List<Shelf> = emptyList(),
)

/** The pure rules behind Home (iOS `HomeView`), kept apart so tests can pin them. */
object HomeContent {
    const val CONTINUE_COUNTED = 8
    const val CONTINUE_SHOWN = 4
    const val COMPLETED_SHOWN = 6

    fun build(
        catalog: CatalogRepository,
        progress: PlaybackProgress,
        downloaded: Set<String>,
        currentTrackID: String?,
        languageFilter: LanguageFilter,
    ): HomeUiState {
        val continueItems = ContinueListening.discourseIDs(progress, downloaded, currentTrackID) { catalog.entry(it) != null }.mapNotNull { id ->
            val entry = catalog.entry(id) ?: return@mapNotNull null
            ContinueItem(entry.discourse, entry.series, progress.positions[id] ?: 0.0, progress.durations[id] ?: 0.0)
        }.take(CONTINUE_COUNTED)

        val groups = mutableListOf<ContinueGroup>()
        for (item in continueItems.take(CONTINUE_SHOWN)) {
            val index = groups.indexOfFirst { it.series.id == item.series.id }
            if (index >= 0) groups[index] = groups[index].copy(items = groups[index].items + item) else groups += ContinueGroup(item.series, listOf(item))
        }

        val completed = progress.listenedCompleted.mapNotNull { id ->
            catalog.entry(id)?.let { CompletedItem(it.discourse, it.series) }
        }.take(COMPLETED_SHOWN)

        val curated = catalog.curated
        val shelves = buildList {
            if (!languageFilter.hidesEnglish) {
                add(Shelf("Popular in English", curated.popularEnglish))
                add(Shelf("Beginner Friendly (English)", curated.beginnerEnglish))
            }
            if (!languageFilter.hidesHindi) {
                add(Shelf("Popular in Hindi", curated.popularHindi))
                add(Shelf("Beginner Friendly (Hindi)", curated.beginnerHindi))
            }
        }.filter { it.series.isNotEmpty() }

        return HomeUiState(continueItems, groups, completed, shelves)
    }

    /** Progress bar fraction; the current track uses the live player values. */
    fun progressFraction(item: ContinueItem, player: PlayerState): Float {
        val isCurrent = player.currentTrackId == item.id
        val position = if (isCurrent) player.currentTime else item.position
        val duration = if (isCurrent && player.duration > 0) player.duration else item.savedDuration
        if (position <= 0 || duration <= 0) return 0f
        return (position / duration).coerceAtMost(1.0).toFloat()
    }
}

/** Home state and actions over the contracts, so real services and fakes swap freely. */
class HomeViewModel(
    private val catalog: CatalogRepository,
    downloads: DownloadManager,
    private val playbackState: PlaybackStateRepository,
    private val player: PlayerController,
    settings: SettingsRepository,
) : ViewModel() {
    val playerState: StateFlow<PlayerState> = player.state

    val state: StateFlow<HomeUiState> = combine(
        playbackState.state,
        downloads.downloadedIDs,
        player.state.map { it.currentTrackId }.distinctUntilChanged(),
        settings.settings.map { it.languageFilter }.distinctUntilChanged(),
    ) { progress, downloaded, current, language ->
        HomeContent.build(catalog, progress, downloaded, current, language)
    }.stateIn(
        viewModelScope,
        SharingStarted.WhileSubscribed(5_000),
        HomeContent.build(
            catalog,
            playbackState.state.value,
            downloads.downloadedIDs.value,
            player.state.value.currentTrackId,
            settings.settings.value.languageFilter,
        ),
    )

    /** Plays the series' downloads as a queue from here, or toggles the current track. */
    fun play(item: ContinueItem) {
        viewModelScope.launch {
            if (player.state.value.currentTrackId == item.id) player.togglePlayPause() else player.play(item.id)
        }
    }

    fun dismissContinue(id: String) {
        viewModelScope.launch { playbackState.dismissFromRecent(id) }
    }

    fun clearContinueListening() {
        val ids = state.value.continueListening.map { it.id }
        viewModelScope.launch { ids.forEach { playbackState.dismissFromRecent(it) } }
    }

    fun dismissCompleted(id: String) {
        viewModelScope.launch { playbackState.dismissListenedComplete(id) }
    }

    fun clearRecentlyCompleted() {
        val ids = state.value.recentlyCompleted.map { it.id }
        viewModelScope.launch { ids.forEach { playbackState.dismissListenedComplete(it) } }
    }

    fun coverURL(seriesID: String): String? = catalog.coverURL(seriesID)
}
