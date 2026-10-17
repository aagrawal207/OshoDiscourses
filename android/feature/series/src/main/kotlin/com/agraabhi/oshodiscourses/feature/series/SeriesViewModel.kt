package com.agraabhi.oshodiscourses.feature.series

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadManager
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadState
import com.agraabhi.oshodiscourses.core.domain.downloads.WaitingReason
import com.agraabhi.oshodiscourses.core.domain.player.PlayerController
import com.agraabhi.oshodiscourses.core.domain.progress.PlaybackStateRepository
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptAvailability
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptRepository
import com.agraabhi.oshodiscourses.core.model.CatalogDiscourse
import com.agraabhi.oshodiscourses.core.model.CatalogRepository
import com.agraabhi.oshodiscourses.core.model.Language
import com.agraabhi.oshodiscourses.core.model.SeriesDescription
import com.agraabhi.oshodiscourses.core.model.SeriesInfo
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.util.Locale

/** One discourse row of the series page. */
data class DiscourseRowState(
    val discourse: CatalogDiscourse,
    val download: DownloadState,
    val isCompleted: Boolean,
    val hasTranscript: Boolean,
    val isCurrentTrack: Boolean,
    val isPlaying: Boolean,
    /** "Downloading..." for 2 s after tapping a row that is not downloaded. */
    val showsDownloadHint: Boolean,
) {
    val isDownloaded: Boolean get() = download == DownloadState.Downloaded
    val isActive: Boolean get() = download.isActive
    val isCurrentlyPlaying: Boolean get() = isCurrentTrack && isPlaying
    val failureMessage: String? get() = (download as? DownloadState.Failed)?.error?.message

    /** The network label shown under a running transfer that cannot move. */
    val waitingLabel: String?
        get() = when (download) {
            DownloadState.WaitingForWifi -> WaitingNotice.label(WaitingReason.WIFI)
            DownloadState.WaitingForConnection -> WaitingNotice.label(WaitingReason.CONNECTION)
            else -> null
        }

    val accessibilityLabel: String
        get() = buildString {
            append("Discourse ${discourse.number}")
            if (isCompleted) append(", completed")
            if (hasTranscript) append(", transcript available")
        }
}

data class SeriesUiState(
    val rows: List<DiscourseRowState>,
    val completedCount: Int,
    val remainingCount: Int,
    /** Shown only while one of this series' own transfers waits on the network. */
    val waitingReason: WaitingReason?,
)

/** State and actions for one series page (iOS `SeriesDetailView`), built on the contracts alone. */
class SeriesViewModel(
    seriesID: String,
    catalog: CatalogRepository,
    private val downloads: DownloadManager,
    private val playbackState: PlaybackStateRepository,
    private val player: PlayerController,
    transcripts: TranscriptRepository,
) : ViewModel() {
    val series: SeriesInfo? = catalog.series(seriesID)
    val discourses: List<CatalogDiscourse> = series?.let(catalog::discourses).orEmpty()
    val description: SeriesDescription? = series?.let { catalog.description(it.name) }
    val transcriptCount: Int = series?.let { catalog.transcriptCount(it.id) } ?: 0

    private val transcriptIDs: Set<String> = discourses
        .filter { transcripts.availability(it.id) != TranscriptAvailability.UNAVAILABLE }
        .map { it.id }
        .toSet()

    private val hintIDs = MutableStateFlow<Set<String>>(emptySet())

    // The player ticks every half second; only these two fields change a row.
    private val nowPlaying = player.state
        .map { it.currentTrackId to it.isPlaying }
        .distinctUntilChanged()

    val state: StateFlow<SeriesUiState> = combine(
        downloads.states,
        playbackState.state.map { it.completedDiscourseIDs }.distinctUntilChanged(),
        nowPlaying,
        hintIDs,
        downloads.waitingReason,
    ) { states, completed, playing, hints, waiting ->
        build(states, completed, playing.first, playing.second, hints, waiting)
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), currentState())

    private fun currentState(): SeriesUiState {
        val playerState = player.state.value
        return build(
            downloads.states.value,
            playbackState.state.value.completedDiscourseIDs,
            playerState.currentTrackId,
            playerState.isPlaying,
            hintIDs.value,
            downloads.waitingReason.value,
        )
    }

    private fun build(
        states: Map<String, DownloadState>,
        completed: Set<String>,
        currentTrackID: String?,
        isPlaying: Boolean,
        hints: Set<String>,
        waiting: WaitingReason?,
    ): SeriesUiState {
        val rows = discourses.map { discourse ->
            DiscourseRowState(
                discourse = discourse,
                download = states[discourse.id] ?: DownloadState.NotDownloaded,
                isCompleted = discourse.id in completed,
                hasTranscript = discourse.id in transcriptIDs,
                isCurrentTrack = currentTrackID == discourse.id,
                isPlaying = isPlaying,
                showsDownloadHint = discourse.id in hints,
            )
        }
        val ownTransferWaits = rows.any { it.isActive && it.download != DownloadState.Queued }
        return SeriesUiState(
            rows = rows,
            completedCount = rows.count { it.isCompleted },
            remainingCount = rows.count { !it.isDownloaded },
            waitingReason = waiting.takeIf { ownTransferWaits },
        )
    }

    /** Row tap: plays the series' downloads from here, or starts the download with a hint. */
    fun onRowTap(discourseID: String) {
        viewModelScope.launch {
            if (downloads.state(discourseID) == DownloadState.Downloaded) {
                player.play(discourseID)
                return@launch
            }
            downloads.enqueue(discourseID)
            hintIDs.update { it + discourseID }
            delay(DOWNLOAD_HINT_MILLIS)
            hintIDs.update { it - discourseID }
        }
    }

    /** The trailing control: cancel, retry, play/pause or GET, depending on the row's state. */
    fun onActionTap(discourseID: String) {
        viewModelScope.launch {
            val download = downloads.state(discourseID)
            when {
                download.isActive -> downloads.cancel(discourseID)
                download == DownloadState.Downloaded -> playOrToggle(discourseID)
                else -> downloads.enqueue(discourseID)
            }
        }
    }

    /** Context-menu Play/Pause. */
    fun togglePlayback(discourseID: String) {
        viewModelScope.launch { playOrToggle(discourseID) }
    }

    private suspend fun playOrToggle(discourseID: String) {
        if (player.state.value.currentTrackId == discourseID) player.togglePlayPause() else player.play(discourseID)
    }

    fun download(discourseID: String) {
        viewModelScope.launch { downloads.enqueue(discourseID) }
    }

    fun removeDownload(discourseID: String) {
        viewModelScope.launch { downloads.delete(discourseID) }
    }

    fun setCompleted(discourseID: String, completed: Boolean) {
        viewModelScope.launch {
            if (completed) playbackState.markCompleted(discourseID) else playbackState.unmarkCompleted(discourseID)
        }
    }

    fun markAll(completed: Boolean) {
        viewModelScope.launch {
            discourses.forEach {
                if (completed) playbackState.markCompleted(it.id) else playbackState.unmarkCompleted(it.id)
            }
        }
    }

    /** "Download All": every discourse not on disk, in catalog order. */
    fun downloadAll() {
        viewModelScope.launch {
            downloads.enqueueAll(discourses.filter { downloads.state(it.id) != DownloadState.Downloaded }.map { it.id })
        }
    }

    fun useMobileData() {
        viewModelScope.launch { downloads.useMobileData() }
    }

    companion object {
        const val DOWNLOAD_HINT_MILLIS: Long = 2_000
    }
}

/** iOS size estimates: 20 MB per Hindi discourse and 30 MB per English one. */
object DownloadEstimate {
    fun perDiscourseMB(language: Language): Int = if (language == Language.HINDI) 20 else 30

    /** "~20 MB" or "~30 MB", for the GET pill. */
    fun perDiscourseLabel(language: Language): String = "~${perDiscourseMB(language)} MB"

    /** "~90 MB", or "~1.2 GB" from 1000 MB (decimal, like the iOS `%.1f` format). */
    fun totalLabel(count: Int, language: Language): String {
        val totalMB = count * perDiscourseMB(language)
        return if (totalMB >= 1000) String.format(Locale.ROOT, "~%.1f GB", totalMB / 1000.0) else "~$totalMB MB"
    }
}

/** Copy of iOS `DownloadWaitingNotice`. */
object WaitingNotice {
    fun label(reason: WaitingReason): String = when (reason) {
        WaitingReason.WIFI -> "Waiting for Wi-Fi"
        WaitingReason.CONNECTION -> "Waiting for a connection"
    }

    fun body(reason: WaitingReason): String = when (reason) {
        WaitingReason.WIFI -> "Downloads use Wi-Fi only. Each discourse is about 20–30 MB."
        WaitingReason.CONNECTION -> "Downloads continue when you're back online."
    }

    const val USE_MOBILE_DATA = "Use Mobile Data"
    const val USE_MOBILE_DATA_HINT = "Downloads now and later can use mobile data. You can change this in Settings."
}
