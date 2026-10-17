package com.agraabhi.oshodiscourses.core.domain.progress

import com.agraabhi.oshodiscourses.core.domain.sync.CloudSnapshot
import kotlinx.coroutines.flow.StateFlow

/**
 * Listening progress (iOS `PlaybackStateService`): positions, durations, recency, completion.
 * Merge rules are convergent and idempotent so devices agree regardless of write order.
 * Times are seconds; dates are epoch milliseconds.
 */
interface PlaybackStateRepository {
    val state: StateFlow<PlaybackProgress>

    /**
     * Saves a position when it is finite and positive. [savedAt] records when the listening
     * happened; null means now, counted only when the position moved by at least 1 s.
     */
    suspend fun savePosition(discourseID: String, position: Double, duration: Double = 0.0, savedAt: Long? = null)

    fun getPosition(discourseID: String): Double = state.value.positions[discourseID] ?: 0.0

    fun getDuration(discourseID: String): Double = state.value.durations[discourseID] ?: 0.0

    /** When this device last moved the position, so a late remote report cannot rewind it. */
    fun lastSaved(discourseID: String): Long? = state.value.savedAt[discourseID]

    /** Clears position and duration and drops it from recent; keeps a save time of [at]. */
    suspend fun clearPosition(discourseID: String, at: Long? = null)

    suspend fun dismissFromRecent(discourseID: String)

    /** Moves to the front of recently played (capped at [MAX_RECENT]) and the play history. */
    suspend fun recordPlay(discourseID: String)

    suspend fun markCompleted(discourseID: String)

    /** Marks completed and puts it at the front of Recently Completed (capped at [MAX_RECENT]). */
    suspend fun markListenedComplete(discourseID: String)

    suspend fun dismissListenedComplete(discourseID: String)

    fun isCompleted(discourseID: String): Boolean = discourseID in state.value.completedDiscourseIDs

    suspend fun unmarkCompleted(discourseID: String)

    fun completedCount(seriesID: String): Int = state.value.completedDiscourseIDs.count { it.startsWith("$seriesID-") }

    /** Progress slice of the sync snapshot; positions are bounded to recently played. */
    fun exportCloudSnapshot(): CloudSnapshot

    /** Union of completed, max of positions, capped union of recency lists. True if changed. */
    suspend fun mergeCloudSnapshot(snapshot: CloudSnapshot): Boolean

    companion object {
        const val MAX_RECENT: Int = 20
        const val AUTO_SAVE_INTERVAL_SECONDS: Long = 10
    }
}

data class PlaybackProgress(
    /** Seconds per discourse. iOS key prefix `playbackPosition_`. */
    val positions: Map<String, Double> = emptyMap(),
    /** Seconds per discourse. iOS key prefix `playbackDuration_`. */
    val durations: Map<String, Double> = emptyMap(),
    /** Epoch ms per discourse. iOS key prefix `playbackSavedAt_`. */
    val savedAt: Map<String, Long> = emptyMap(),
    /** Newest first, capped at 20. iOS key `recentlyPlayed`. */
    val recentlyPlayed: List<String> = emptyList(),
    /** iOS key `completedDiscourseIDs`. */
    val completedDiscourseIDs: Set<String> = emptySet(),
    /** Recently Completed on Home, newest first, capped at 20. iOS key `listenedCompletedIDs`. */
    val listenedCompleted: List<String> = emptyList(),
    /** Uncapped play history. iOS key `allPlayedDiscourseIDs`. */
    val allPlayedDiscourseIDs: List<String> = emptyList(),
)
