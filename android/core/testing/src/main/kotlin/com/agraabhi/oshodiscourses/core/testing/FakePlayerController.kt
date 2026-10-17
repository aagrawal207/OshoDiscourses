package com.agraabhi.oshodiscourses.core.testing

import com.agraabhi.oshodiscourses.core.domain.bookmarks.BookmarkRepository
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadManager
import com.agraabhi.oshodiscourses.core.domain.player.PlayResult
import com.agraabhi.oshodiscourses.core.domain.player.PlayerController
import com.agraabhi.oshodiscourses.core.domain.player.PlayerState
import com.agraabhi.oshodiscourses.core.domain.player.QueueItem
import com.agraabhi.oshodiscourses.core.model.BoostLevel
import com.agraabhi.oshodiscourses.core.model.CatalogRepository
import com.agraabhi.oshodiscourses.core.model.PlaybackSpeed
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlin.math.abs

/**
 * Moves state instantly with no audio. With [downloads] set, only downloaded discourses play,
 * as on a device; without it every catalog discourse plays. [state] is writable for previews.
 */
class FakePlayerController(
    private val catalog: CatalogRepository = FakeCatalogRepository(),
    private val downloads: DownloadManager? = null,
    private val bookmarks: BookmarkRepository? = null,
    initial: PlayerState = PlayerState(),
    /** Duration every loaded discourse reports, in seconds. */
    private val fakeDuration: Double = 5_400.0,
) : PlayerController {
    override val state: MutableStateFlow<PlayerState> = MutableStateFlow(initial)

    override suspend fun play(discourseID: String, from: Double?): PlayResult {
        if (state.value.currentTrackId == discourseID) {
            from?.let { seek(it) }
            resume()
            return PlayResult.Started
        }
        val entry = catalog.entry(discourseID) ?: return PlayResult.Failure.UNKNOWN_DISCOURSE
        val playable = catalog.discourses(entry.series).filter { downloads == null || downloads.localFileURI(it.id) != null }
        val start = playable.indexOfFirst { it.id == discourseID }
        if (start < 0) return PlayResult.Failure.NOT_DOWNLOADED
        val items = playable.map { QueueItem(it.id, downloads?.localFileURI(it.id) ?: it.audioURL, it.displayTitle, entry.series.name) }
        playQueue(items, start, from)
        return PlayResult.Started
    }

    override suspend fun playBookmark(bookmarkID: String): PlayResult {
        val bookmark = bookmarks?.bookmarks?.value?.firstOrNull { it.id == bookmarkID } ?: return PlayResult.Failure.UNKNOWN_BOOKMARK
        return play(bookmark.discourseID, bookmark.timestamp)
    }

    override suspend fun playQueue(items: List<QueueItem>, startIndex: Int, resumeAt: Double?) {
        if (items.isEmpty()) return
        val index = startIndex.coerceIn(0, items.lastIndex)
        load(items, index, resumeAt ?: 0.0)
    }

    private fun load(items: List<QueueItem>, index: Int, position: Double) {
        val item = items[index]
        state.update {
            it.copy(
                currentTrackId = item.id,
                currentTitle = item.title,
                currentSeries = item.series,
                queue = items,
                currentIndex = index,
                currentTime = position,
                duration = fakeDuration,
                isPlaying = true,
                isBuffering = false,
                previousPosition = null,
                error = null,
            )
        }
    }

    override suspend fun playQueueItem(index: Int) {
        val s = state.value
        if (index !in s.queue.indices || index == s.currentIndex) return
        load(s.queue, index, 0.0)
    }

    override suspend fun pause() = state.update { it.copy(isPlaying = false) }

    override suspend fun resume() = state.update { if (it.hasTrack) it.copy(isPlaying = true) else it }

    override suspend fun togglePlayPause() = if (state.value.isPlaying) pause() else resume()

    override suspend fun setPlaying(playing: Boolean) = if (playing) resume() else pause()

    override suspend fun seek(to: Double) = state.update {
        val upper = if (it.duration > 0) it.duration else Double.MAX_VALUE
        it.copy(currentTime = to.coerceIn(0.0, upper))
    }

    override suspend fun seekWithHistory(to: Double) {
        val current = state.value.currentTime
        if (abs(current - to) > PlayerController.HISTORY_THRESHOLD_SECONDS) state.update { it.copy(previousPosition = current) }
        seek(to)
    }

    override suspend fun returnToPreviousPosition() {
        val previous = state.value.previousPosition ?: return
        val current = state.value.currentTime
        seek(previous)
        state.update { it.copy(previousPosition = current) }
    }

    override suspend fun clearPositionHistory() = state.update { it.copy(previousPosition = null) }

    override suspend fun skipForward(seconds: Double) {
        val s = state.value
        if (s.duration > 0 && s.currentTime + seconds >= s.duration - 1) {
            if (s.hasNext) skipToNext() else state.update { it.copy(isPlaying = false, currentTime = it.duration) }
        } else {
            seek(s.currentTime + seconds)
        }
    }

    override suspend fun skipBackward(seconds: Double) = seek(maxOf(state.value.currentTime - seconds, 0.0))

    override suspend fun skipToNext() {
        val s = state.value
        if (s.hasNext) load(s.queue, s.currentIndex + 1, 0.0)
    }

    override suspend fun skipToPrevious() {
        val s = state.value
        if (s.currentTime > PlayerController.RESTART_THRESHOLD_SECONDS || !s.hasPrevious) seek(0.0) else load(s.queue, s.currentIndex - 1, 0.0)
    }

    override suspend fun setRate(rate: Float) = state.update { it.copy(playbackRate = PlaybackSpeed.normalized(rate)) }

    override suspend fun setVolume(gain: Float) = state.update { it.copy(volume = gain.coerceIn(0f, BoostLevel.MAXIMUM_GAIN)) }

    override suspend fun stop() = state.update {
        PlayerState(playbackRate = it.playbackRate, volume = it.volume)
    }
}
