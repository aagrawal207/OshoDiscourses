package com.agraabhi.oshodiscourses.core.data.progress

import com.agraabhi.oshodiscourses.core.data.AtomicJsonFile
import com.agraabhi.oshodiscourses.core.data.LocalChangeSource
import com.agraabhi.oshodiscourses.core.data.json.PlaybackStateJson
import com.agraabhi.oshodiscourses.core.domain.progress.PlaybackProgress
import com.agraabhi.oshodiscourses.core.domain.progress.PlaybackStateRepository
import com.agraabhi.oshodiscourses.core.domain.progress.PlaybackStateRepository.Companion.MAX_RECENT
import com.agraabhi.oshodiscourses.core.domain.sync.CloudSnapshot
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import kotlin.math.abs
import kotlin.math.roundToLong

/**
 * [PlaybackStateRepository] in `playback_state.json` (iOS `PlaybackStateService` over
 * UserDefaults). Mutations run one at a time under a lock and write the file before returning.
 * The constructor reads the file on the calling thread.
 */
class FilePlaybackStateRepository(
    directory: File,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val clock: () -> Long = System::currentTimeMillis,
) : PlaybackStateRepository, LocalChangeSource {

    private val file = AtomicJsonFile(File(directory, FILE_NAME), PlaybackStateJson.serializer())
    private val mutex = Mutex()
    private val mutable = MutableStateFlow(file.read()?.toProgress() ?: PlaybackProgress())
    private val changes = MutableSharedFlow<Unit>(extraBufferCapacity = 1, onBufferOverflow = BufferOverflow.DROP_OLDEST)

    override val state: StateFlow<PlaybackProgress> = mutable.asStateFlow()
    override val localChanges: SharedFlow<Unit> = changes.asSharedFlow()

    /**
     * Called when a merge moves a discourse's position forward. A paused player showing that
     * discourse must seek, or its next auto-save writes the older position back.
     */
    @Volatile
    var onRemotePositionAdvanced: ((discourseID: String, position: Double) -> Unit)? = null

    override suspend fun savePosition(discourseID: String, position: Double, duration: Double, savedAt: Long?) {
        if (!position.isFinite() || position <= 0) return
        edit { s ->
            // Auto-save rewrites a paused position every tick; only movement counts as listening.
            val stamp = savedAt ?: if (abs((s.positions[discourseID] ?: 0.0) - position) >= 1) clock() else null
            stored(s, discourseID, position, duration).let { if (stamp != null) it.copy(savedAt = it.savedAt + (discourseID to stamp)) else it }
        }
    }

    override suspend fun clearPosition(discourseID: String, at: Long?) = edit { s ->
        s.copy(
            positions = s.positions - discourseID,
            durations = s.durations - discourseID,
            savedAt = s.savedAt + (discourseID to (at ?: clock())),
            recentlyPlayed = s.recentlyPlayed - discourseID,
        )
    }

    override suspend fun dismissFromRecent(discourseID: String) = edit { it.copy(recentlyPlayed = it.recentlyPlayed - discourseID) }

    override suspend fun recordPlay(discourseID: String) = edit { s ->
        s.copy(
            recentlyPlayed = movedToFront(s.recentlyPlayed, discourseID).take(MAX_RECENT),
            allPlayedDiscourseIDs = movedToFront(s.allPlayedDiscourseIDs, discourseID),
        )
    }

    override suspend fun markCompleted(discourseID: String) = edit { s ->
        s.copy(
            completedDiscourseIDs = s.completedDiscourseIDs + discourseID,
            allPlayedDiscourseIDs = movedToFront(s.allPlayedDiscourseIDs, discourseID),
        )
    }

    override suspend fun markListenedComplete(discourseID: String) = edit { s ->
        s.copy(
            completedDiscourseIDs = s.completedDiscourseIDs + discourseID,
            listenedCompleted = movedToFront(s.listenedCompleted, discourseID).take(MAX_RECENT),
            allPlayedDiscourseIDs = movedToFront(s.allPlayedDiscourseIDs, discourseID),
        )
    }

    override suspend fun dismissListenedComplete(discourseID: String) = edit { it.copy(listenedCompleted = it.listenedCompleted - discourseID) }

    override suspend fun unmarkCompleted(discourseID: String) = edit { it.copy(completedDiscourseIDs = it.completedDiscourseIDs - discourseID) }

    override fun exportCloudSnapshot(): CloudSnapshot = export(mutable.value)

    override suspend fun mergeCloudSnapshot(snapshot: CloudSnapshot): Boolean {
        var advanced: Map<String, Double> = emptyMap()
        val changed = mutate(local = false) { s ->
            val (merged, moved) = merge(s, snapshot)
            advanced = moved
            merged
        }
        val callback = onRemotePositionAdvanced
        if (callback != null) advanced.forEach { (id, position) -> callback(id, position) }
        return changed
    }

    private suspend fun edit(transform: (PlaybackProgress) -> PlaybackProgress) {
        mutate(local = true, transform)
    }

    /** True when the state changed; the file is written before this returns. */
    private suspend fun mutate(local: Boolean = true, transform: (PlaybackProgress) -> PlaybackProgress): Boolean {
        val changed = mutex.withLock {
            val before = mutable.value
            val after = transform(before)
            if (after == before) return@withLock false
            mutable.value = after
            withContext(ioDispatcher) { file.writeQuietly(after.toJson()) }
            true
        }
        if (changed && local) changes.tryEmit(Unit)
        return changed
    }

    companion object {
        const val FILE_NAME: String = "playback_state.json"

        /** Union of two ordered recency lists, cloud entries first, deduplicated and capped. */
        fun mergeList(cloud: List<String>, local: List<String>, cap: Int): List<String> =
            LinkedHashSet<String>(cloud.size + local.size).apply { addAll(cloud); addAll(local) }.take(cap)

        internal fun export(s: PlaybackProgress): CloudSnapshot {
            // Bounded to recently played so the payload stays small; completion is sent in full.
            val positions = LinkedHashMap<String, Double>()
            val durations = LinkedHashMap<String, Double>()
            for (id in s.recentlyPlayed) {
                s.positions[id]?.takeIf { it > 0 }?.let { positions[id] = it }
                s.durations[id]?.takeIf { it > 0 }?.let { durations[id] = it }
            }
            return CloudSnapshot(
                positions = positions,
                durations = durations,
                recentlyPlayed = s.recentlyPlayed,
                completed = s.completedDiscourseIDs.toList(),
                listenedCompleted = s.listenedCompleted,
                played = s.allPlayedDiscourseIDs,
            )
        }

        /**
         * iOS `mergeCloudSnapshot`: larger position and duration win, completion is a union,
         * recency lists put cloud entries first. Returns the result and the positions that moved.
         */
        internal fun merge(local: PlaybackProgress, snapshot: CloudSnapshot): Pair<PlaybackProgress, Map<String, Double>> {
            var s = local
            val advanced = LinkedHashMap<String, Double>()
            for ((id, cloudPosition) in snapshot.positions) {
                if (!cloudPosition.isFinite() || cloudPosition <= (s.positions[id] ?: 0.0)) continue
                val cloudDuration = snapshot.durations[id] ?: (s.durations[id] ?: 0.0)
                // Another device's listening: this device's save time stays as it was.
                s = stored(s, id, cloudPosition, cloudDuration)
                advanced[id] = cloudPosition
            }
            for ((id, cloudDuration) in snapshot.durations) {
                if (cloudDuration.isFinite() && cloudDuration > (s.durations[id] ?: 0.0)) {
                    s = s.copy(durations = s.durations + (id to cloudDuration))
                }
            }
            val played = snapshot.played ?: (snapshot.recentlyPlayed + snapshot.completed)
            s = s.copy(
                completedDiscourseIDs = s.completedDiscourseIDs + snapshot.completed,
                recentlyPlayed = mergeList(snapshot.recentlyPlayed, s.recentlyPlayed, MAX_RECENT),
                listenedCompleted = mergeList(snapshot.listenedCompleted, s.listenedCompleted, MAX_RECENT),
                allPlayedDiscourseIDs = mergeList(played, s.allPlayedDiscourseIDs, Int.MAX_VALUE),
            )
            return s to advanced
        }

        private fun stored(s: PlaybackProgress, id: String, position: Double, duration: Double) = s.copy(
            positions = s.positions + (id to position),
            durations = if (duration.isFinite() && duration > 0) s.durations + (id to duration) else s.durations,
        )

        private fun movedToFront(list: List<String>, id: String): List<String> = listOf(id) + (list - id)

        private fun PlaybackStateJson.toProgress() = PlaybackProgress(
            positions = playbackPosition,
            durations = playbackDuration,
            savedAt = playbackSavedAt.mapValues { (it.value * 1000).roundToLong() },
            recentlyPlayed = recentlyPlayed,
            completedDiscourseIDs = completedDiscourseIDs.toSet(),
            listenedCompleted = listenedCompletedIDs,
            allPlayedDiscourseIDs = allPlayedDiscourseIDs,
        )

        private fun PlaybackProgress.toJson() = PlaybackStateJson(
            playbackPosition = positions,
            playbackDuration = durations,
            playbackSavedAt = savedAt.mapValues { it.value / 1000.0 },
            recentlyPlayed = recentlyPlayed,
            completedDiscourseIDs = completedDiscourseIDs.toList(),
            listenedCompletedIDs = listenedCompleted,
            allPlayedDiscourseIDs = allPlayedDiscourseIDs,
        )
    }
}
