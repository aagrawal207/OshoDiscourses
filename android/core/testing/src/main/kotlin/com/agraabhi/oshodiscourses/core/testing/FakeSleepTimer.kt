package com.agraabhi.oshodiscourses.core.testing

import com.agraabhi.oshodiscourses.core.domain.sleep.SleepTimer
import com.agraabhi.oshodiscourses.core.domain.sleep.SleepTimerMode
import com.agraabhi.oshodiscourses.core.domain.sleep.SleepTimerState
import kotlinx.coroutines.flow.MutableStateFlow

/** No ticking; call [expire] to simulate the deadline. */
class FakeSleepTimer(initial: SleepTimerState = SleepTimerState()) : SleepTimer {
    override val state: MutableStateFlow<SleepTimerState> = MutableStateFlow(initial)
    var expirations: Int = 0
        private set

    override suspend fun start(minutes: Int) {
        state.value = SleepTimerState(SleepTimerMode.COUNTDOWN, minutes * 60.0)
    }

    override suspend fun startUntilEndOfDiscourse() {
        state.value = SleepTimerState(SleepTimerMode.END_OF_DISCOURSE)
    }

    override suspend fun cancel() {
        state.value = SleepTimerState()
    }

    override suspend fun discourseDidFinish() {
        if (state.value.mode == SleepTimerMode.END_OF_DISCOURSE) expire()
    }

    fun expire() {
        expirations++
        state.value = SleepTimerState()
    }
}
