package com.agraabhi.oshodiscourses.billing

import kotlinx.coroutines.CompletableDeferred

/** Opens once; every waiter, earlier or later, then proceeds (iOS `TipTestGate`). */
internal class Gate {
    private val opened = CompletableDeferred<Unit>()

    fun open() {
        opened.complete(Unit)
    }

    suspend fun await() = opened.await()
}
