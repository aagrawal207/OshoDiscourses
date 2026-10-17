package com.agraabhi.oshodiscourses.denoise.dsp

import java.util.concurrent.Executor
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.ThreadFactory
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** Background threads for model loads and deferred DSP resets; never the audio thread. */
internal object DspExecutors {
    val modelLoader: ExecutorService = Executors.newCachedThreadPool(daemon("osho-dfn-load"))
    val maintenance: ExecutorService = Executors.newSingleThreadExecutor(daemon("osho-dsp-maintenance"))

    private fun daemon(name: String): ThreadFactory {
        val count = AtomicInteger()
        return ThreadFactory { runnable ->
            Thread(runnable, "$name-${count.incrementAndGet()}").apply { isDaemon = true }
        }
    }
}

/**
 * A coalescing trigger like iOS `DispatchSourceUserDataAdd`: any number of [signal] calls
 * before the handler runs schedule it once, and the render path never allocates a task.
 */
internal class CoalescedTask(private val executor: Executor, private val handler: () -> Unit) {
    private val scheduled = AtomicBoolean(false)
    private val runnable = Runnable {
        scheduled.set(false)
        handler()
    }

    fun signal() {
        if (scheduled.compareAndSet(false, true)) executor.execute(runnable)
    }
}
