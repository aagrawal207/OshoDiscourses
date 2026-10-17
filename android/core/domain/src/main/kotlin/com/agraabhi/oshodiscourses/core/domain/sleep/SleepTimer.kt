package com.agraabhi.oshodiscourses.core.domain.sleep

import kotlinx.coroutines.flow.StateFlow

/**
 * Countdown and end-of-discourse sleep modes (iOS `SleepTimerService`). The countdown runs
 * against an absolute deadline so it stays correct across drift and process suspension.
 * On expiry the implementation pauses the player.
 */
interface SleepTimer {
    val state: StateFlow<SleepTimerState>

    /** Starts a countdown, replacing any armed timer. */
    suspend fun start(minutes: Int)

    /** Stops playback when the current discourse ends; auto-play next is suppressed while armed. */
    suspend fun startUntilEndOfDiscourse()

    suspend fun cancel()

    /** Called by the player on a natural finish; fires only in end-of-discourse mode. */
    suspend fun discourseDidFinish()

    companion object {
        /** The player's sleep menu, in order. */
        val PRESET_MINUTES: List<Int> = listOf(5, 10, 15, 30, 45, 60)
    }
}

enum class SleepTimerMode { OFF, COUNTDOWN, END_OF_DISCOURSE }

data class SleepTimerState(
    val mode: SleepTimerMode = SleepTimerMode.OFF,
    /** Seconds left in countdown mode; 0 otherwise. */
    val remainingTime: Double = 0.0,
) {
    val isActive: Boolean get() = mode != SleepTimerMode.OFF

    /** "m:ss". */
    val formattedRemaining: String
        get() {
            val total = remainingTime.toInt()
            return "%d:%02d".format(total / 60, total % 60)
        }

    /** Short label for the player's Sleep button. */
    val statusLabel: String
        get() = when (mode) {
            SleepTimerMode.OFF -> "Sleep"
            SleepTimerMode.COUNTDOWN -> formattedRemaining
            SleepTimerMode.END_OF_DISCOURSE -> "End"
        }
}
