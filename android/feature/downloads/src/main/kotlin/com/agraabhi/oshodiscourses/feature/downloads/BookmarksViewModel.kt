package com.agraabhi.oshodiscourses.feature.downloads

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.agraabhi.oshodiscourses.core.domain.bookmarks.Bookmark
import com.agraabhi.oshodiscourses.core.domain.bookmarks.BookmarkCategory
import com.agraabhi.oshodiscourses.core.domain.bookmarks.BookmarkRepository
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadManager
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadState
import com.agraabhi.oshodiscourses.core.domain.player.PlayerController
import com.agraabhi.oshodiscourses.core.model.CatalogRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

internal enum class BookmarkAvailability { DOWNLOADED, DOWNLOADING, NOT_DOWNLOADED }

internal data class BookmarkRowState(val bookmark: Bookmark, val availability: BookmarkAvailability, val isPlaying: Boolean)

internal data class BookmarkGroup(val seriesName: String, val rows: List<BookmarkRowState>)

internal data class BookmarksUiState(
    val hasBookmarks: Boolean = false,
    val filter: BookmarkCategory? = null,
    val groups: List<BookmarkGroup> = emptyList(),
)

/** iOS `BookmarksView`: category filter, series groups, play or download from each row. */
internal class BookmarksViewModel(
    private val bookmarks: BookmarkRepository,
    private val downloads: DownloadManager,
    private val player: PlayerController,
    private val catalog: CatalogRepository,
) : ViewModel() {
    private val filter = MutableStateFlow<BookmarkCategory?>(null)

    val state: StateFlow<BookmarksUiState> = combine(
        bookmarks.bookmarks,
        filter,
        downloads.states,
        downloads.downloadedIDs,
        player.state,
    ) { all, category, states, downloaded, p ->
        build(all, category, states, downloaded, p.currentTrackId, p.isPlaying)
    }.stateIn(
        viewModelScope,
        SharingStarted.Eagerly,
        build(
            bookmarks.bookmarks.value,
            null,
            downloads.states.value,
            downloads.downloadedIDs.value,
            player.state.value.currentTrackId,
            player.state.value.isPlaying,
        ),
    )

    private fun build(
        all: List<Bookmark>,
        category: BookmarkCategory?,
        states: Map<String, DownloadState>,
        downloaded: Set<String>,
        currentTrackId: String?,
        isPlaying: Boolean,
    ): BookmarksUiState {
        val shown = if (category == null) all else all.filter { it.category == category }
        val groups = shown
            .groupBy { it.seriesName }
            .map { (series, items) ->
                BookmarkGroup(
                    series,
                    items.sortedByDescending { it.createdAt }.map { b ->
                        val availability = when {
                            b.discourseID in downloaded -> BookmarkAvailability.DOWNLOADED
                            (states[b.discourseID] ?: DownloadState.NotDownloaded).isActive -> BookmarkAvailability.DOWNLOADING
                            else -> BookmarkAvailability.NOT_DOWNLOADED
                        }
                        BookmarkRowState(b, availability, isPlaying && currentTrackId == b.discourseID)
                    },
                )
            }
            .sortedBy { it.seriesName }
        return BookmarksUiState(hasBookmarks = all.isNotEmpty(), filter = category, groups = groups)
    }

    /** Tapping the active chip returns to All, as on iOS. */
    fun selectFilter(category: BookmarkCategory?) {
        filter.value = if (category != null && filter.value == category) null else category
    }

    /** Seeks with history when the discourse is current, otherwise plays from the moment. */
    fun play(bookmarkID: String) = viewModelScope.launch { player.playBookmark(bookmarkID) }

    fun download(discourseID: String) = viewModelScope.launch {
        if (catalog.entry(discourseID) != null) downloads.enqueue(discourseID)
    }

    fun delete(bookmarkID: String) = viewModelScope.launch { bookmarks.remove(bookmarkID) }
}
