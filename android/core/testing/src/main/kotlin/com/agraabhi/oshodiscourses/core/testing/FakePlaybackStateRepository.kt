package com.agraabhi.oshodiscourses.core.testing

import com.agraabhi.oshodiscourses.core.domain.progress.PlaybackProgress
import com.agraabhi.oshodiscourses.core.domain.progress.PlaybackStateRepository
import com.agraabhi.oshodiscourses.core.domain.sync.CloudSnapshot
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import kotlin.math.abs

/** In-memory progress with the iOS caps; merges are simple unions, not the real rules. */
class FakePlaybackStateRepository(
    initial: PlaybackProgress = PlaybackProgress(),
    private val clock: FakeClock = FakeClock(),
) : PlaybackStateRepository {
    override val state = MutableStateFlow(initial)
    var mergedSnapshots: Int = 0
        private set

    override suspend fun savePosition(discourseID: String, position: Double, duration: Double, savedAt: Long?) {
        if (!position.isFinite() || position <= 0) return
        state.update { s ->
            val moved = abs((s.positions[discourseID] ?: 0.0) - position) >= 1
            val stamp = savedAt ?: if (moved) clock.nowMillis else null
            s.copy(
                positions = s.positions + (discourseID to position),
                durations = if (duration.isFinite() && duration > 0) s.durations + (discourseID to duration) else s.durations,
                savedAt = if (stamp != null) s.savedAt + (discourseID to stamp) else s.savedAt,
            )
        }
    }

    override suspend fun clearPosition(discourseID: String, at: Long?) = state.update {
        it.copy(
            positions = it.positions - discourseID,
            durations = it.durations - discourseID,
            savedAt = it.savedAt + (discourseID to (at ?: clock.nowMillis)),
            recentlyPlayed = it.recentlyPlayed - discourseID,
        )
    }

    override suspend fun dismissFromRecent(discourseID: String) = state.update { it.copy(recentlyPlayed = it.recentlyPlayed - discourseID) }

    override suspend fun recordPlay(discourseID: String) = state.update {
        it.copy(
            recentlyPlayed = (listOf(discourseID) + (it.recentlyPlayed - discourseID)).take(PlaybackStateRepository.MAX_RECENT),
            allPlayedDiscourseIDs = if (discourseID in it.allPlayedDiscourseIDs) it.allPlayedDiscourseIDs else it.allPlayedDiscourseIDs + discourseID,
        )
    }

    override suspend fun markCompleted(discourseID: String) = state.update { it.copy(completedDiscourseIDs = it.completedDiscourseIDs + discourseID) }

    override suspend fun markListenedComplete(discourseID: String) = state.update {
        it.copy(
            completedDiscourseIDs = it.completedDiscourseIDs + discourseID,
            listenedCompleted = (listOf(discourseID) + (it.listenedCompleted - discourseID)).take(PlaybackStateRepository.MAX_RECENT),
        )
    }

    override suspend fun dismissListenedComplete(discourseID: String) = state.update { it.copy(listenedCompleted = it.listenedCompleted - discourseID) }

    override suspend fun unmarkCompleted(discourseID: String) = state.update { it.copy(completedDiscourseIDs = it.completedDiscourseIDs - discourseID) }

    override fun exportCloudSnapshot(): CloudSnapshot {
        val s = state.value
        return CloudSnapshot(
            positions = s.positions.filterKeys { it in s.recentlyPlayed },
            durations = s.durations.filterKeys { it in s.recentlyPlayed },
            recentlyPlayed = s.recentlyPlayed,
            completed = s.completedDiscourseIDs.toList(),
            listenedCompleted = s.listenedCompleted,
            played = s.allPlayedDiscourseIDs,
        )
    }

    override suspend fun mergeCloudSnapshot(snapshot: CloudSnapshot): Boolean {
        mergedSnapshots++
        val before = state.value
        state.update { s ->
            s.copy(
                positions = s.positions + snapshot.positions.filter { (id, p) -> p > (s.positions[id] ?: 0.0) },
                durations = snapshot.durations + s.durations,
                completedDiscourseIDs = s.completedDiscourseIDs + snapshot.completed,
                recentlyPlayed = (s.recentlyPlayed + snapshot.recentlyPlayed).distinct().take(PlaybackStateRepository.MAX_RECENT),
            )
        }
        return state.value != before
    }
}
