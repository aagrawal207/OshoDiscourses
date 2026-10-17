package com.agraabhi.oshodiscourses.core.data.sync

import com.agraabhi.oshodiscourses.core.data.LocalChangeSource
import com.agraabhi.oshodiscourses.core.data.json.CloudSnapshotCodec
import com.agraabhi.oshodiscourses.core.domain.bookmarks.BookmarkRepository
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadManager
import com.agraabhi.oshodiscourses.core.domain.progress.PlaybackStateRepository
import com.agraabhi.oshodiscourses.core.domain.stats.ListeningStatsRepository
import com.agraabhi.oshodiscourses.core.domain.sync.CloudSnapshot
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptStateRepository
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.merge

/**
 * Builds the one synced [CloudSnapshot] from every repository and merges an incoming one back
 * (iOS `CloudSyncService.push` and `pull`). The Drive transport only moves the bytes.
 */
class CloudSnapshotCoordinator(
    private val playbackState: PlaybackStateRepository,
    private val bookmarks: BookmarkRepository,
    private val listeningStats: ListeningStatsRepository,
    private val transcriptState: TranscriptStateRepository,
    private val downloads: DownloadManager,
) {
    /**
     * Fires on local progress, bookmark and transcript changes, when iOS pushes. Download
     * history is not included; observe [DownloadManager.downloadHistory] for that.
     */
    val localChanges: Flow<Unit> = listOf(playbackState, bookmarks, transcriptState)
        .mapNotNull { (it as? LocalChangeSource)?.localChanges }
        .let { if (it.isEmpty()) emptyFlow() else it.merge() }

    fun export(): CloudSnapshot = playbackState.exportCloudSnapshot().copy(
        bookmarks = bookmarks.bookmarks.value,
        deletedBookmarkIDs = bookmarks.deletedBookmarkIDs.value,
        dailyStats = listeningStats.syncedDailyStats(),
        downloaded = downloads.syncedDownloadHistory(),
        transcripts = transcriptState.syncedStates(),
    )

    /** [export] in the iOS wire format, for the Drive file body. */
    fun exportBytes(): ByteArray = CloudSnapshotCodec.encode(export())

    /** Merges into every repository with its convergent rule. Merging never triggers [localChanges]. */
    suspend fun merge(snapshot: CloudSnapshot): CloudMergeResult = CloudMergeResult(
        progress = playbackState.mergeCloudSnapshot(snapshot),
        bookmarks = bookmarks.mergeSynced(snapshot.bookmarks, snapshot.deletedBookmarkIDs.orEmpty()),
        listeningStats = listeningStats.mergeSyncedStats(snapshot.dailyStats),
        downloadHistory = downloads.mergeSyncedDownloadHistory(snapshot.downloaded),
        transcripts = transcriptState.mergeSynced(snapshot.transcripts.orEmpty()),
    )

    /** Throws [kotlinx.serialization.SerializationException] or [IllegalArgumentException] for a malformed body. */
    suspend fun mergeBytes(bytes: ByteArray): CloudMergeResult = merge(CloudSnapshotCodec.decode(bytes))
}

/** Which repositories a merge changed. */
data class CloudMergeResult(
    val progress: Boolean,
    val bookmarks: Boolean,
    val listeningStats: Boolean,
    val downloadHistory: Boolean,
    val transcripts: Boolean,
) {
    val anyChanged: Boolean get() = progress || bookmarks || listeningStats || downloadHistory || transcripts
}
