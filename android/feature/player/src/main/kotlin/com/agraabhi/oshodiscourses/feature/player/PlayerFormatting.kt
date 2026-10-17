package com.agraabhi.oshodiscourses.feature.player

import com.agraabhi.oshodiscourses.core.domain.denoise.DenoiseState
import com.agraabhi.oshodiscourses.core.domain.player.AudioProcessingStatus
import com.agraabhi.oshodiscourses.core.domain.sleep.SleepTimerMode
import com.agraabhi.oshodiscourses.core.domain.sleep.SleepTimerState
import com.agraabhi.oshodiscourses.core.model.BoostLevel
import kotlin.math.abs

/** Pure copy and number rules shared by the player screens, kept apart so they are unit tested. */
object PlayerFormatting {
    /** "m:ss", or "h:mm:ss" from an hour; invalid or negative time shows "0:00". */
    fun time(seconds: Double): String {
        if (!seconds.isFinite() || seconds < 0) return "0:00"
        val total = seconds.toLong()
        val hrs = total / 3600
        val mins = (total % 3600) / 60
        val secs = total % 60
        return if (hrs > 0) "%d:%02d:%02d".format(hrs, mins, secs) else "%d:%02d".format(mins, secs)
    }

    /**
     * Mini-player line 1. `currentTitle` stays "<series> - #N" for the lock screen, so the number
     * is parsed back out; null when there is no series or the suffix is not all digits.
     */
    fun discourseLine(title: String, series: String): String? {
        if (series.isEmpty()) return null
        val hash = title.lastIndexOf('#')
        if (hash < 0) return null
        val number = title.substring(hash + 1)
        if (number.isEmpty() || !number.all(Char::isDigit)) return null
        return "Discourse $number"
    }

    fun seriesLine(title: String, series: String): String = series.ifEmpty { title }

    /** The player's series title; "Not Playing" with nothing loaded. */
    fun playerTitle(title: String, series: String): String = when {
        series.isNotEmpty() -> series
        title.isNotEmpty() -> title
        else -> "Not Playing"
    }

    /** The countdown preset to tick: `ceil(remaining / 60)` minutes, as iOS rounds partial minutes up. */
    fun checkedSleepMinutes(state: SleepTimerState): Int? {
        if (state.mode != SleepTimerMode.COUNTDOWN) return null
        val total = state.remainingTime.toInt()
        return total / 60 + if (total % 60 > 0) 1 else 0
    }

    /** Nearest boost step to the saved gain, so an off-ladder value still selects a segment. */
    fun boostLevel(gain: Float): BoostLevel = BoostLevel.entries.minBy { abs(it.gain - gain) }

    /** Volume Boost footer: the first rule that matches wins. */
    fun boostExplanation(state: DenoiseState): String = when {
        !state.isEnabled -> "Turn on DeNoise to use volume boost. It raises the volume after reducing noise."
        state.boostGain <= 1f -> "Boost is off. Choose a level to make quiet recordings louder."
        state.isBoostAvailable -> "Makes quiet recordings louder after reducing noise."
        state.status.isIssue -> "Your level is saved. Boost is paused until noise reduction is working again."
        else -> "Your level is saved. Boost will apply when enhanced audio starts playing."
    }

    enum class StatusIcon { ISSUE, ACTIVE, WAITING, PREPARING, IDLE }

    fun statusIcon(status: AudioProcessingStatus): StatusIcon = when {
        status.isIssue -> StatusIcon.ISSUE
        status == AudioProcessingStatus.Active -> StatusIcon.ACTIVE
        status == AudioProcessingStatus.WaitingForPlayback -> StatusIcon.WAITING
        status == AudioProcessingStatus.Preparing ||
            status == AudioProcessingStatus.LoadingModel ||
            status == AudioProcessingStatus.ModelReady -> StatusIcon.PREPARING
        else -> StatusIcon.IDLE
    }
}
