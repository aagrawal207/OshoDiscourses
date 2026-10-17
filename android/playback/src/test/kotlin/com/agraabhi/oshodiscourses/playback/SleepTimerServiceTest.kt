package com.agraabhi.oshodiscourses.playback

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.agraabhi.oshodiscourses.core.domain.sleep.SleepTimerMode
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runTest
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

/**
 * Ports iOS `SleepTimerTests`: the mode state machine, and that end-of-discourse fires only on
 * `discourseDidFinish()` while the countdown fires only at its deadline.
 */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(AndroidJUnit4::class)
@Config(sdk = [36])
class SleepTimerServiceTest {
    private fun TestScope.timer(): Pair<SleepTimerService, () -> Int> {
        var fired = 0
        val timer = SleepTimerService(backgroundScope, now = { testScheduler.currentTime })
        timer.onExpire = { fired++ }
        return timer to { fired }
    }

    @Test
    fun startsOff() = runTest(UnconfinedTestDispatcher()) {
        val (timer, _) = timer()
        assertThat(timer.state.value.mode).isEqualTo(SleepTimerMode.OFF)
        assertThat(timer.state.value.isActive).isFalse()
        assertThat(timer.state.value.statusLabel).isEqualTo("Sleep")
    }

    @Test
    fun countdownSetsModeAndRemaining() = runTest(UnconfinedTestDispatcher()) {
        val (timer, _) = timer()
        timer.start(10)
        assertThat(timer.state.value.mode).isEqualTo(SleepTimerMode.COUNTDOWN)
        assertThat(timer.state.value.isActive).isTrue()
        assertThat(timer.state.value.remainingTime).isEqualTo(600.0)
        assertThat(timer.state.value.statusLabel).isEqualTo("10:00")
        timer.cancel()
    }

    @Test
    fun endOfDiscourseSetsModeWithNoCountdown() = runTest(UnconfinedTestDispatcher()) {
        val (timer, _) = timer()
        timer.startUntilEndOfDiscourse()
        assertThat(timer.state.value.mode).isEqualTo(SleepTimerMode.END_OF_DISCOURSE)
        assertThat(timer.state.value.isActive).isTrue()
        assertThat(timer.state.value.remainingTime).isEqualTo(0.0)
        assertThat(timer.state.value.statusLabel).isEqualTo("End")
    }

    @Test
    fun discourseDidFinishFiresOnlyInEndOfDiscourseMode() = runTest(UnconfinedTestDispatcher()) {
        val (timer, fired) = timer()
        timer.start(30)
        timer.discourseDidFinish()
        assertThat(fired()).isEqualTo(0)
        assertThat(timer.state.value.mode).isEqualTo(SleepTimerMode.COUNTDOWN)

        timer.startUntilEndOfDiscourse()
        timer.discourseDidFinish()
        assertThat(fired()).isEqualTo(1)
        assertThat(timer.state.value.mode).isEqualTo(SleepTimerMode.OFF)
    }

    @Test
    fun discourseDidFinishIsNoopWhenOff() = runTest(UnconfinedTestDispatcher()) {
        val (timer, fired) = timer()
        timer.discourseDidFinish()
        assertThat(fired()).isEqualTo(0)
    }

    @Test
    fun cancelResetsEverything() = runTest(UnconfinedTestDispatcher()) {
        val (timer, _) = timer()
        timer.startUntilEndOfDiscourse()
        timer.cancel()
        assertThat(timer.state.value.mode).isEqualTo(SleepTimerMode.OFF)
        assertThat(timer.state.value.remainingTime).isEqualTo(0.0)
        assertThat(timer.state.value.isActive).isFalse()
    }

    @Test
    fun countdownTicksFromTheDeadlineAndFiresOnce() = runTest(UnconfinedTestDispatcher()) {
        val (timer, fired) = timer()
        timer.start(5)
        advanceTimeBy(61_500)
        assertThat(timer.state.value.remainingTime).isEqualTo(239.0)
        assertThat(timer.state.value.formattedRemaining).isEqualTo("3:59")
        advanceTimeBy(238_000)
        assertThat(fired()).isEqualTo(0)
        advanceTimeBy(1_000)
        assertThat(fired()).isEqualTo(1)
        assertThat(timer.state.value.mode).isEqualTo(SleepTimerMode.OFF)
        advanceTimeBy(600_000)
        assertThat(fired()).isEqualTo(1)
    }

    @Test
    fun startingAgainReplacesTheArmedTimer() = runTest(UnconfinedTestDispatcher()) {
        val (timer, fired) = timer()
        timer.start(5)
        advanceTimeBy(200_000)
        timer.start(15)
        assertThat(timer.state.value.remainingTime).isEqualTo(900.0)
        advanceTimeBy(300_000)
        assertThat(fired()).isEqualTo(0)
        advanceTimeBy(600_001)
        assertThat(fired()).isEqualTo(1)
    }

    @Test
    fun cancelStopsTheCountdownFromFiring() = runTest(UnconfinedTestDispatcher()) {
        val (timer, fired) = timer()
        timer.start(5)
        timer.cancel()
        advanceTimeBy(600_000)
        assertThat(fired()).isEqualTo(0)
    }
}
