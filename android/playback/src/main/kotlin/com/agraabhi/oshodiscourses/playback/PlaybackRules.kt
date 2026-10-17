package com.agraabhi.oshodiscourses.playback

import kotlin.math.max

/** What a forward skip does (iOS `AudioPlayerService.SkipOutcome`). */
sealed interface SkipOutcome {
    data class Seek(val target: Double) : SkipOutcome

    data object Finish : SkipOutcome
}

/**
 * Pure decisions behind the player, kept free of ExoPlayer so they are unit-testable
 * (the `nonisolated static` helpers of iOS `AudioPlayerService` and `PlaybackStateService`).
 */
object PlaybackRules {
    /** Seconds before the end at which Smart Download fetches the next discourse. */
    const val SMART_DOWNLOAD_LEAD_SECONDS: Double = 20.0

    /** Shorter talks rely on the completion fallback instead of the early trigger. */
    const val SMART_DOWNLOAD_MIN_DURATION_SECONDS: Double = 30.0

    /** A saved position this close to the end restarts the talk instead of finishing it at once. */
    const val RESUME_END_MARGIN_SECONDS: Double = 5.0

    const val AUTO_SAVE_INTERVAL_MS: Long = 10_000

    const val PROGRESS_INTERVAL_MS: Long = 500

    /** A duration of 0 or less is "not known yet": advance, never finish. */
    fun skipForwardOutcome(anchor: Double, seconds: Double, duration: Double): SkipOutcome =
        if (duration > 0 && anchor + seconds >= duration - 1) SkipOutcome.Finish else SkipOutcome.Seek(anchor + seconds)

    fun skipBackwardTarget(anchor: Double, seconds: Double): Double = max(anchor - seconds, 0.0)

    /** A manual jump into the last 5 s makes the finish "not natural", so no review prompt follows. */
    fun isNearEndSeek(target: Double, duration: Double): Boolean = duration > 0 && target >= duration - 5

    /** The first downloaded id strictly after [current] in series order; never goes backwards. */
    fun nextDownloadedId(current: String, orderedIds: List<String>, isDownloaded: (String) -> Boolean): String? {
        val index = orderedIds.indexOf(current)
        if (index < 0) return null
        return orderedIds.drop(index + 1).firstOrNull(isDownloaded)
    }

    /**
     * Whether the media delta between two 10 s auto-save ticks is listening or a seek. One tick
     * covers up to 10 × rate seconds of media plus 5 s of jitter; slow rates keep the 1× window.
     */
    fun isContinuousListening(delta: Double, rate: Float): Boolean =
        delta > 0 && delta <= 10 * max(rate, 1f).toDouble() + 5

    /** Resume only when playback was running before the interruption and the system allows it. */
    fun shouldResumeAfterInterruption(wasPlaying: Boolean, systemAllowsResume: Boolean): Boolean =
        wasPlaying && systemAllowsResume

    fun shouldTriggerSmartDownload(position: Double, duration: Double): Boolean =
        duration > SMART_DOWNLOAD_MIN_DURATION_SECONDS && position >= duration - SMART_DOWNLOAD_LEAD_SECONDS

    /**
     * Where a loaded talk starts (null = the beginning). An explicit position stops 1 s short of the
     * end, which would otherwise finish, Smart Delete and advance at once.
     */
    fun startPosition(explicit: Double?, saved: Double, duration: Double): Double? {
        if (explicit != null && explicit.isFinite() && duration > 0) {
            return explicit.coerceIn(0.0, duration - 1)
        }
        val candidate = explicit ?: saved
        return if (candidate.isFinite() && candidate > 0 && candidate < duration - RESUME_END_MARGIN_SECONDS) candidate else null
    }
}
