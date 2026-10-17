package com.agraabhi.oshodiscourses.playback

import android.os.SystemClock
import android.util.Log
import com.agraabhi.oshodiscourses.core.domain.sleep.SleepTimer
import com.agraabhi.oshodiscourses.core.domain.sleep.SleepTimerMode
import com.agraabhi.oshodiscourses.core.domain.sleep.SleepTimerState
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.coroutines.ContinuationInterceptor
import kotlin.math.min

/**
 * iOS `SleepTimerService`. Expiry stops playback abruptly, as on iOS (no fade-out).
 * Wire [onExpire] to `player.setPlaying(false)`, which also stops a next talk that is still loading.
 */
class SleepTimerService(
    private val scope: CoroutineScope,
    /** Milliseconds on a clock that keeps counting while the device sleeps. */
    private val now: () -> Long = SystemClock::elapsedRealtime,
) : SleepTimer {
    private val dispatcher: CoroutineDispatcher =
        scope.coroutineContext[ContinuationInterceptor] as? CoroutineDispatcher ?: Dispatchers.Main.immediate
    private val mutableState = MutableStateFlow(SleepTimerState())
    override val state: StateFlow<SleepTimerState> = mutableState.asStateFlow()

    var onExpire: (suspend () -> Unit)? = null

    private var countdown: Job? = null

    override suspend fun start(minutes: Int): Unit = withContext(dispatcher) {
        cancelNow()
        val durationMs = minutes * 60_000L
        mutableState.value = SleepTimerState(SleepTimerMode.COUNTDOWN, durationMs / 1000.0)
        // Remaining time comes from an absolute deadline: delay() guarantees at least its
        // interval, so decrementing per tick drifts and would stall while the process is frozen.
        val deadline = now() + durationMs
        countdown = scope.launch {
            while (isActive) {
                val remaining = deadline - now()
                if (remaining <= 0) {
                    fire()
                    return@launch
                }
                mutableState.value = SleepTimerState(SleepTimerMode.COUNTDOWN, remaining / 1000.0)
                delay(min(1_000L, remaining))
            }
        }
        Log.i(TAG, "outcome=countdown_started minutes=$minutes")
        Unit
    }

    override suspend fun startUntilEndOfDiscourse(): Unit = withContext(dispatcher) {
        cancelNow()
        mutableState.value = SleepTimerState(SleepTimerMode.END_OF_DISCOURSE)
        Log.i(TAG, "outcome=end_of_discourse_armed")
        Unit
    }

    override suspend fun cancel(): Unit = withContext(dispatcher) { cancelNow() }

    override suspend fun discourseDidFinish(): Unit = withContext(dispatcher) {
        if (mutableState.value.mode == SleepTimerMode.END_OF_DISCOURSE) fire()
    }

    private fun cancelNow() {
        countdown?.cancel()
        countdown = null
        mutableState.value = SleepTimerState()
    }

    /** The callback runs in its own coroutine because firing cancels the countdown job it may run in. */
    private fun fire() {
        val callback = onExpire
        cancelNow()
        Log.i(TAG, "outcome=expired")
        if (callback != null) scope.launch { callback() }
    }

    private companion object {
        const val TAG = "SleepTimer"
    }
}
