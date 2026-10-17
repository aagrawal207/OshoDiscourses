package com.agraabhi.oshodiscourses.core.domain.sync

import com.agraabhi.oshodiscourses.core.domain.bookmarks.Bookmark
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptSyncedState
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable

/**
 * Silent cross-device sync of one [CloudSnapshot] through the user's Google Drive app-data
 * folder (iOS `CloudSyncService` over iCloud key-value storage). No server and no merge UI:
 * every merge rule is convergent and idempotent. Pushes follow progress auto-saves and
 * bookmark changes; pulls merge into the repositories without pushing back.
 */
interface SyncController {
    val status: StateFlow<SyncStatus>

    /** Starts observing repositories and does an initial pull, merge and push. Idempotent. */
    suspend fun start()

    /** Pull, merge, then push the merged result. */
    suspend fun syncNow()

    /** Asks for Drive app-data access; the implementation shows consent on the foreground activity. */
    suspend fun requestAuthorization()

    /** Stops syncing and forgets the authorization on this device. */
    suspend fun signOut()

    /**
     * Signs out and also withdraws the app's Drive grant from the account; the synced file stays.
     * False when the provider could not be reached. The device is signed out either way.
     */
    suspend fun disconnect(): Boolean {
        signOut()
        return true
    }
}

sealed interface SyncStatus {
    /** Not started, or the user has never connected an account. */
    data object Idle : SyncStatus

    /** Drive access was never granted or was revoked; sync is inert until [SyncController.requestAuthorization]. */
    data object SignInNeeded : SyncStatus

    data object Syncing : SyncStatus

    /** [lastSyncedAt] is epoch milliseconds. */
    data class UpToDate(val lastSyncedAt: Long) : SyncStatus

    data class Failed(val message: String) : SyncStatus
}

/**
 * The synced slice of user data, same shape as iOS `CloudSnapshot` (key `cloud.progress.v1`).
 * Times are seconds; positions are bounded to recently played; `completed` is the full set.
 */
@Serializable
data class CloudSnapshot(
    val positions: Map<String, Double> = emptyMap(),
    val durations: Map<String, Double> = emptyMap(),
    val recentlyPlayed: List<String> = emptyList(),
    val completed: List<String> = emptyList(),
    val listenedCompleted: List<String> = emptyList(),
    /** Uncapped play history; null in older snapshots, seeded from recent + completed. */
    val played: List<String>? = null,
    val bookmarks: List<Bookmark> = emptyList(),
    val deletedBookmarkIDs: List<String>? = null,
    /** `yyyy-MM-dd` to seconds; merged by max per day. */
    val dailyStats: Map<String, Double> = emptyMap(),
    /** Every discourse ever downloaded; union-merged. */
    val downloaded: List<String> = emptyList(),
    val transcripts: Map<String, TranscriptSyncedState>? = null,
) {
    companion object {
        const val SNAPSHOT_KEY: String = "cloud.progress.v1"
    }
}
