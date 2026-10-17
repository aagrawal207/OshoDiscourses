package com.agraabhi.oshodiscourses.feature.player

import com.agraabhi.oshodiscourses.core.domain.denoise.DenoiseState
import com.agraabhi.oshodiscourses.core.domain.player.AudioMixFailure
import com.agraabhi.oshodiscourses.core.domain.player.AudioProcessingStatus
import com.agraabhi.oshodiscourses.core.domain.sleep.SleepTimerMode
import com.agraabhi.oshodiscourses.core.domain.sleep.SleepTimerState
import com.agraabhi.oshodiscourses.core.model.BoostLevel
import com.agraabhi.oshodiscourses.feature.player.PlayerFormatting.StatusIcon
import com.google.common.truth.Truth.assertThat
import org.junit.Test

class PlayerFormattingTest {
    @Test
    fun timeUsesMinutesUntilAnHour() {
        assertThat(PlayerFormatting.time(0.0)).isEqualTo("0:00")
        assertThat(PlayerFormatting.time(503.9)).isEqualTo("8:23")
        assertThat(PlayerFormatting.time(3_599.0)).isEqualTo("59:59")
        assertThat(PlayerFormatting.time(5_901.0)).isEqualTo("1:38:21")
    }

    @Test
    fun invalidTimeShowsZero() {
        assertThat(PlayerFormatting.time(-1.0)).isEqualTo("0:00")
        assertThat(PlayerFormatting.time(Double.NaN)).isEqualTo("0:00")
        assertThat(PlayerFormatting.time(Double.POSITIVE_INFINITY)).isEqualTo("0:00")
    }

    @Test
    fun discourseLineNeedsADigitSuffixAndASeries() {
        assertThat(PlayerFormatting.discourseLine("A Bird on the Wing - #12", "A Bird on the Wing")).isEqualTo("Discourse 12")
        assertThat(PlayerFormatting.discourseLine("A Bird on the Wing - #", "A Bird on the Wing")).isNull()
        assertThat(PlayerFormatting.discourseLine("Talk #2b", "Series")).isNull()
        assertThat(PlayerFormatting.discourseLine("No number", "Series")).isNull()
        assertThat(PlayerFormatting.discourseLine("A - #1", "")).isNull()
    }

    @Test
    fun seriesLineFallsBackToTheTitle() {
        assertThat(PlayerFormatting.seriesLine("Title", "")).isEqualTo("Title")
        assertThat(PlayerFormatting.seriesLine("Title", "Series")).isEqualTo("Series")
        assertThat(PlayerFormatting.playerTitle("", "")).isEqualTo("Not Playing")
    }

    @Test
    fun sleepCheckRoundsPartialMinutesUp() {
        assertThat(PlayerFormatting.checkedSleepMinutes(SleepTimerState(SleepTimerMode.COUNTDOWN, 900.0))).isEqualTo(15)
        assertThat(PlayerFormatting.checkedSleepMinutes(SleepTimerState(SleepTimerMode.COUNTDOWN, 872.0))).isEqualTo(15)
        assertThat(PlayerFormatting.checkedSleepMinutes(SleepTimerState(SleepTimerMode.COUNTDOWN, 840.0))).isEqualTo(14)
        assertThat(PlayerFormatting.checkedSleepMinutes(SleepTimerState(SleepTimerMode.END_OF_DISCOURSE))).isNull()
    }

    @Test
    fun boostLevelPicksTheNearestStep() {
        assertThat(PlayerFormatting.boostLevel(2f)).isEqualTo(BoostLevel.MEDIUM)
        assertThat(PlayerFormatting.boostLevel(2.6f)).isEqualTo(BoostLevel.HIGH)
        assertThat(PlayerFormatting.boostLevel(1.1f)).isEqualTo(BoostLevel.OFF)
        assertThat(PlayerFormatting.boostLevel(9f)).isEqualTo(BoostLevel.MAX)
    }

    @Test
    fun boostExplanationFirstMatchWins() {
        val off = DenoiseState(isEnabled = false, boostGain = 1f)
        assertThat(PlayerFormatting.boostExplanation(off)).startsWith("Turn on DeNoise")
        val enabledNoBoost = DenoiseState(isEnabled = true, boostGain = 1f, status = AudioProcessingStatus.Active, isProcessorAttached = true)
        assertThat(PlayerFormatting.boostExplanation(enabledNoBoost)).startsWith("Boost is off.")
        val active = enabledNoBoost.copy(boostGain = 2f)
        assertThat(PlayerFormatting.boostExplanation(active)).isEqualTo("Makes quiet recordings louder after reducing noise.")
        val issue = active.copy(status = AudioProcessingStatus.SetupFailed(AudioMixFailure.TAP_CREATION))
        assertThat(PlayerFormatting.boostExplanation(issue)).isEqualTo("Your level is saved. Boost is paused until noise reduction is working again.")
        val waiting = active.copy(status = AudioProcessingStatus.WaitingForPlayback)
        assertThat(PlayerFormatting.boostExplanation(waiting)).isEqualTo("Your level is saved. Boost will apply when enhanced audio starts playing.")
    }

    @Test
    fun statusIconsFollowIOS() {
        assertThat(PlayerFormatting.statusIcon(AudioProcessingStatus.Bypassing)).isEqualTo(StatusIcon.ISSUE)
        assertThat(PlayerFormatting.statusIcon(AudioProcessingStatus.Active)).isEqualTo(StatusIcon.ACTIVE)
        assertThat(PlayerFormatting.statusIcon(AudioProcessingStatus.WaitingForPlayback)).isEqualTo(StatusIcon.WAITING)
        assertThat(PlayerFormatting.statusIcon(AudioProcessingStatus.LoadingModel)).isEqualTo(StatusIcon.PREPARING)
        assertThat(PlayerFormatting.statusIcon(AudioProcessingStatus.Off)).isEqualTo(StatusIcon.IDLE)
    }
}
