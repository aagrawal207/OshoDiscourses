package com.agraabhi.oshodiscourses.core.testing

import com.agraabhi.oshodiscourses.core.domain.sync.SyncController
import com.agraabhi.oshodiscourses.core.domain.sync.SyncStatus
import kotlinx.coroutines.flow.MutableStateFlow

class FakeSyncController(
    initial: SyncStatus = SyncStatus.Idle,
    private val clock: FakeClock = FakeClock(),
) : SyncController {
    override val status = MutableStateFlow(initial)
    var syncCount: Int = 0
        private set
    var authorized: Boolean = initial != SyncStatus.SignInNeeded

    override suspend fun start() = syncNow()

    override suspend fun syncNow() {
        if (!authorized) {
            status.value = SyncStatus.SignInNeeded
            return
        }
        syncCount++
        status.value = SyncStatus.UpToDate(clock.nowMillis)
    }

    override suspend fun requestAuthorization() {
        authorized = true
        syncNow()
    }

    override suspend fun signOut() {
        authorized = false
        status.value = SyncStatus.SignInNeeded
    }

    /** What [disconnect] reports, as if Google was or was not reachable. */
    var revokeSucceeds: Boolean = true
    var disconnectCount: Int = 0
        private set

    override suspend fun disconnect(): Boolean {
        disconnectCount++
        signOut()
        return revokeSucceeds
    }
}
