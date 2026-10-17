package com.agraabhi.oshodiscourses.core.domain.player

import kotlinx.coroutines.flow.StateFlow

/**
 * The one process-wide player (iOS `AudioPlayerService` + `PlaybackLauncher`).
 *
 * Playback is download-only, as on iOS: [play] builds a queue of the series' downloaded
 * discourses in catalog order, so auto-play continues through the series. Implementations
 * persist the chosen rate and boost through `SettingsRepository`, auto-save positions every
 * 10 s through `PlaybackStateRepository`, and drive the media notification and lock screen.
 */
interface PlayerController {
    val state: StateFlow<PlayerState>

    /**
     * Resumes [discourseID] if it is current, otherwise starts its series queue there.
     * [from] overrides the saved position (seconds), e.g. for "Play from here".
     */
    suspend fun play(discourseID: String, from: Double? = null): PlayResult

    /** Plays a bookmark's discourse from its timestamp, seeking with history if already current. */
    suspend fun playBookmark(bookmarkID: String): PlayResult

    /** `resumeAt` overrides the saved position of the starting item. */
    suspend fun playQueue(items: List<QueueItem>, startIndex: Int = 0, resumeAt: Double? = null)

    /** Jumps to an Up Next entry; no-op when out of range or already current. */
    suspend fun playQueueItem(index: Int)

    suspend fun pause()

    suspend fun resume()

    suspend fun togglePlayPause()

    /** Idempotent play/pause for remote controls: a repeated request never flips the state back. */
    suspend fun setPlaying(playing: Boolean)

    suspend fun seek(to: Double)

    /** Seeks and remembers where playback was when the jump is longer than 10 s (Kindle style). */
    suspend fun seekWithHistory(to: Double)

    /** Returns to [PlayerState.previousPosition], swapping it with the current position. */
    suspend fun returnToPreviousPosition()

    suspend fun clearPositionHistory()

    /** Skips forward; finishes the discourse when the target is within 1 s of a known end. */
    suspend fun skipForward(seconds: Double = SKIP_FORWARD_SECONDS)

    suspend fun skipBackward(seconds: Double = SKIP_BACKWARD_SECONDS)

    suspend fun skipToNext()

    /** Restarts the current discourse when more than 3 s in, otherwise goes to the previous one. */
    suspend fun skipToPrevious()

    /** Snaps to the `PlaybackSpeed` grid and persists it as the default rate. */
    suspend fun setRate(rate: Float)

    /** Output gain 0..4; above 1 it is the DeNoise boost and is persisted as `volumeBoost`. */
    suspend fun setVolume(gain: Float)

    /** Unloads the discourse and clears the media session. */
    suspend fun stop()

    companion object {
        const val SKIP_FORWARD_SECONDS: Double = 30.0
        const val SKIP_BACKWARD_SECONDS: Double = 15.0

        /** Rewinding past this point restarts the discourse instead of going to the previous one. */
        const val RESTART_THRESHOLD_SECONDS: Double = 3.0

        /** Jumps shorter than this do not record a position to return to. */
        const val HISTORY_THRESHOLD_SECONDS: Double = 10.0
    }
}

/** One entry in the play queue (iOS `AudioPlayerService.QueueItem`). */
data class QueueItem(
    val id: String,
    /** Local file URI of the downloaded audio. */
    val uri: String,
    val title: String,
    val series: String,
)

/** Observable player state (the iOS `AudioPlayerService` published properties). */
data class PlayerState(
    val currentTrackId: String? = null,
    val currentTitle: String = "",
    val currentSeries: String = "",
    val isPlaying: Boolean = false,
    /** Wants to play but is waiting for data or a seek to land. */
    val isBuffering: Boolean = false,
    /** Seconds. */
    val currentTime: Double = 0.0,
    /** Seconds; 0 while unknown. */
    val duration: Double = 0.0,
    val playbackRate: Float = 1f,
    /** Output gain; values above 1 are the boost. */
    val volume: Float = 1f,
    val queue: List<QueueItem> = emptyList(),
    val currentIndex: Int = 0,
    /** Where playback was before the last long jump, for "Go back". */
    val previousPosition: Double? = null,
    val error: PlaybackError? = null,
    val audioProcessingStatus: AudioProcessingStatus = AudioProcessingStatus.Off,
    /** Boost is applied only while noise reduction is actually processing audio. */
    val isBoostAvailable: Boolean = false,
) {
    val hasTrack: Boolean get() = currentTrackId != null
    val hasNext: Boolean get() = currentIndex < queue.size - 1
    val hasPrevious: Boolean get() = currentIndex > 0
    val hasPreviousPosition: Boolean get() = previousPosition != null
    val upNext: List<QueueItem> get() = if (hasNext) queue.subList(currentIndex + 1, queue.size) else emptyList()
}

/** Why [PlayerController.play] did not start playback (iOS `PlaybackLauncher.Failure`). */
sealed interface PlayResult {
    data object Started : PlayResult

    enum class Failure(val message: String) : PlayResult {
        UNKNOWN_DISCOURSE("This discourse is no longer in the catalog."),
        NOT_DOWNLOADED("Download this discourse first."),
        UNKNOWN_BOOKMARK("This bookmark was removed."),
    }
}

/** A playback failure surfaced to the player UI. */
data class PlaybackError(val message: String)
