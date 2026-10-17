package com.agraabhi.oshodiscourses.feature.downloads

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.agraabhi.oshodiscourses.core.domain.bookmarks.BookmarkRepository
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadManager
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadState
import com.agraabhi.oshodiscourses.core.domain.downloads.WaitingReason
import com.agraabhi.oshodiscourses.core.domain.player.PlayerController
import com.agraabhi.oshodiscourses.core.domain.stats.ListeningStatsRepository
import com.agraabhi.oshodiscourses.core.model.CatalogDiscourse
import com.agraabhi.oshodiscourses.core.model.CatalogRepository
import com.agraabhi.oshodiscourses.core.model.Language
import com.agraabhi.oshodiscourses.core.model.SeriesInfo
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

internal data class InProgressItem(val discourse: CatalogDiscourse, val isQueued: Boolean, val progress: Double)

internal data class DownloadedItem(val discourse: CatalogDiscourse, val sizeText: String?)

internal data class DownloadedGroup(val series: SeriesInfo, val items: List<DownloadedItem>, val sizeText: String?) {
    val subtitle: String get() = listOfNotNull("${items.size} episodes", sizeText).joinToString(" · ")
}

internal data class RedownloadItem(val discourse: CatalogDiscourse, val state: DownloadState) {
    val isDownloading: Boolean get() = state.isActive
    val isQueued: Boolean get() = state == DownloadState.Queued
    val progress: Double get() = (state as? DownloadState.Downloading)?.progress ?: 0.0

    /** Size guess on the GET pill before anything is fetched. */
    val estimatedSize: String get() = if (discourse.language == Language.HINDI) "~20 MB" else "~30 MB"
}

/** Everything the Downloads tab shows (iOS `DownloadsView` computed properties). */
internal data class DownloadsUiState(
    val query: String = "",
    val isEditing: Boolean = false,
    val selection: Set<String> = emptySet(),
    val inProgress: List<InProgressItem> = emptyList(),
    val waitingReason: WaitingReason? = null,
    val groups: List<DownloadedGroup> = emptyList(),
    val downloadedCount: Int = 0,
    val totalBytes: Long = 0,
    val previouslyDownloaded: List<RedownloadItem> = emptyList(),
    val listenedSeconds: Double = 0.0,
    val bookmarkCount: Int = 0,
    val currentTrackId: String? = null,
    val isPlaying: Boolean = false,
) {
    val isSearching: Boolean get() = query.isNotEmpty()
    val showInProgress: Boolean get() = !isEditing && !isSearching && inProgress.isNotEmpty()
    val showPreviouslyDownloaded: Boolean get() = !isEditing && !isSearching && previouslyDownloaded.isNotEmpty()
    val showUsage: Boolean get() = totalBytes > 0 && !isSearching
    val statsSubtitle: String get() = Formats.listenedSubtitle(listenedSeconds)

    fun isPlayingNow(discourseID: String): Boolean = currentTrackId == discourseID && isPlaying
}

/** Inputs from the download engine, grouped so `combine` stays typed. */
private data class DownloadInputs(
    val downloaded: Set<String>,
    val states: Map<String, DownloadState>,
    val history: Set<String>,
    val waiting: WaitingReason?,
    val sizes: Map<String, Long>,
)

private data class LocalInputs(val query: String, val editing: Boolean, val selection: Set<String>)

/** State holder for the Downloads tab; every action goes through the `:core:domain` contracts. */
internal class DownloadsViewModel(
    private val catalog: CatalogRepository,
    private val downloads: DownloadManager,
    private val player: PlayerController,
    bookmarks: BookmarkRepository,
    stats: ListeningStatsRepository,
) : ViewModel() {
    private val query = MutableStateFlow("")
    private val editing = MutableStateFlow(false)
    private val selection = MutableStateFlow(emptySet<String>())
    private val sizes = MutableStateFlow(emptyMap<String, Long>())

    init {
        viewModelScope.launch {
            downloads.downloadedIDs.collectLatest { sizes.value = downloads.downloadedSizes() }
        }
    }

    private val downloadInputs = combine(
        downloads.downloadedIDs,
        downloads.states,
        downloads.downloadHistory,
        downloads.waitingReason,
        sizes,
        ::DownloadInputs,
    )

    private val localInputs = combine(query, editing, selection, ::LocalInputs)

    val state: StateFlow<DownloadsUiState> = combine(
        downloadInputs,
        localInputs,
        player.state,
        bookmarks.bookmarks,
        stats.stats,
    ) { d, l, p, b, s ->
        build(d, l, p.currentTrackId, p.isPlaying, b.size, s.totalAllTime)
    }.stateIn(
        viewModelScope,
        SharingStarted.Eagerly,
        build(
            DownloadInputs(
                downloads.downloadedIDs.value,
                downloads.states.value,
                downloads.downloadHistory.value,
                downloads.waitingReason.value,
                emptyMap(),
            ),
            LocalInputs("", false, emptySet()),
            player.state.value.currentTrackId,
            player.state.value.isPlaying,
            bookmarks.bookmarks.value.size,
            stats.stats.value.totalAllTime,
        ),
    )

    private fun build(
        d: DownloadInputs,
        l: LocalInputs,
        currentTrackId: String?,
        isPlaying: Boolean,
        bookmarkCount: Int,
        listened: Double,
    ): DownloadsUiState {
        val entries = d.downloaded.mapNotNull { catalog.entry(it) }
        val allGroups = entries
            .groupBy { it.series.id }
            .values
            .map { group -> group.first().series to group.map { it.discourse }.sortedBy { it.number } }
            .sortedBy { it.first.name }

        val needle = l.query.lowercase()
        val filtered = allGroups.mapNotNull { (series, discourses) ->
            if (needle.isEmpty()) return@mapNotNull series to discourses
            val seriesMatches = series.name.lowercase().contains(needle)
            val matches = discourses.filter { seriesMatches || it.displayTitle.lowercase().contains(needle) }
            if (matches.isEmpty()) null else series to matches
        }
        val groups = filtered.map { (series, discourses) ->
            val bytes = discourses.sumOf { d.sizes[it.id] ?: 0L }
            DownloadedGroup(
                series = series,
                items = discourses.map { DownloadedItem(it, d.sizes[it.id]?.takeIf { b -> b > 0 }?.let(Formats::bytes)) },
                sizeText = if (bytes > 0) Formats.bytes(bytes) else null,
            )
        }

        val inProgress = downloads.inProgressIDs().mapNotNull { id ->
            val discourse = catalog.entry(id)?.discourse ?: return@mapNotNull null
            val state = d.states[id] ?: DownloadState.Queued
            InProgressItem(discourse, state == DownloadState.Queued, (state as? DownloadState.Downloading)?.progress ?: 0.0)
        }

        val previously = (d.history - d.downloaded)
            .mapNotNull { catalog.entry(it)?.discourse }
            .filterNot { (d.states[it.id] ?: DownloadState.NotDownloaded).isActive }
            .sortedWith(compareBy<CatalogDiscourse> { it.seriesName }.thenBy { it.number })
            .map { RedownloadItem(it, d.states[it.id] ?: DownloadState.NotDownloaded) }

        return DownloadsUiState(
            query = l.query,
            isEditing = l.editing,
            selection = l.selection,
            inProgress = inProgress,
            waitingReason = d.waiting,
            groups = groups,
            downloadedCount = d.downloaded.size,
            totalBytes = d.sizes.values.sum(),
            previouslyDownloaded = previously,
            listenedSeconds = listened,
            bookmarkCount = bookmarkCount,
            currentTrackId = currentTrackId,
            isPlaying = isPlaying,
        )
    }

    fun setQuery(value: String) {
        query.value = value
    }

    fun startEditing() {
        editing.value = true
    }

    fun exitEditing() {
        editing.value = false
        selection.value = emptySet()
    }

    fun toggleSelection(discourseID: String) = selection.update { if (discourseID in it) it - discourseID else it + discourseID }

    fun deleteSelection() {
        val ids = selection.value.toList()
        exitEditing()
        viewModelScope.launch { downloads.deleteDownloads(ids) }
    }

    fun deleteAll() {
        exitEditing()
        viewModelScope.launch { downloads.deleteAll() }
    }

    fun deleteSeries(seriesID: String) = viewModelScope.launch { downloads.deleteSeries(seriesID) }

    fun delete(discourseID: String) = viewModelScope.launch { downloads.delete(discourseID) }

    /** Row tap: starts the series queue here, or resumes when it is already loaded. */
    fun play(discourseID: String) = viewModelScope.launch { player.play(discourseID) }

    /** The row's play/pause circle and the context menu's Play/Pause. */
    fun playOrPause(discourseID: String) = viewModelScope.launch {
        if (player.state.value.currentTrackId == discourseID) player.togglePlayPause() else player.play(discourseID)
    }

    fun cancel(discourseID: String) = viewModelScope.launch { downloads.cancel(discourseID) }

    fun download(discourseID: String) = viewModelScope.launch { downloads.enqueue(discourseID) }

    fun forget(discourseID: String) = viewModelScope.launch { downloads.forgetDownloadHistory(listOf(discourseID)) }

    fun useMobileData() = viewModelScope.launch { downloads.useMobileData() }
}
