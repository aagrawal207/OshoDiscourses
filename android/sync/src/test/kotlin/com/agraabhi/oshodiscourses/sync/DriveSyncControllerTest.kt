package com.agraabhi.oshodiscourses.sync

import com.agraabhi.oshodiscourses.core.domain.sync.CloudSnapshot
import com.agraabhi.oshodiscourses.core.domain.sync.SyncStatus
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class DriveSyncControllerTest {
    private val api = FakeDriveApi()
    private val store = FakeSnapshotStore()
    private val auth = FakeAuthorizer()
    private val prefs = InMemorySyncPreferences(enabled = true)
    private val scheduler = FakeScheduler()
    private val changes = MutableSharedFlow<Unit>(extraBufferCapacity = 16)
    private val visibility = MutableSharedFlow<Boolean>(extraBufferCapacity = 16)

    private fun TestScope.controller() = DriveSyncController(
        store = store,
        api = api,
        authorizer = auth,
        preferences = prefs,
        scheduler = scheduler,
        scope = backgroundScope,
        localChanges = changes,
        appVisibility = visibility,
        clock = { testScheduler.currentTime },
    )

    private fun localChange(transform: (CloudSnapshot) -> CloudSnapshot) {
        store.edit(transform)
        check(changes.tryEmit(Unit))
    }

    // Opt-in and authorization

    @Test
    fun notConnectedStartAsksForSignInAndStaysOffline() = runTest {
        prefs.enabled = false
        val sync = controller()

        sync.start()

        assertEquals(SyncStatus.SignInNeeded, sync.status.value)
        assertTrue(api.calls.isEmpty())
        assertEquals(0, scheduler.periodic)
    }

    @Test
    fun requestAuthorizationEnablesSyncAndPushesLocalData() = runTest {
        prefs.enabled = false
        store.local = CloudSnapshot(positions = mapOf("d-1" to 30.0))
        val sync = controller()

        sync.requestAuthorization()

        assertEquals(1, auth.interactiveRequests)
        assertTrue(prefs.enabled)
        assertEquals("listener@example.com", prefs.accountName)
        assertEquals(1, scheduler.periodic)
        assertEquals(mapOf("d-1" to 30.0), api.only().positions)
        assertIs<SyncStatus.UpToDate>(sync.status.value)
    }

    @Test
    fun declinedConsentKeepsSyncOff() = runTest {
        prefs.enabled = false
        auth.interactive = AuthOutcome.NeedsConsent
        val sync = controller()

        sync.requestAuthorization()

        assertEquals(SyncStatus.SignInNeeded, sync.status.value)
        assertEquals(false, prefs.enabled)
        assertTrue(api.calls.isEmpty())
    }

    @Test
    fun revokedGrantOnLaunchAsksForSignInWithoutShowingConsent() = runTest {
        auth.silent = AuthOutcome.NeedsConsent
        val sync = controller()

        sync.start()

        assertEquals(SyncStatus.SignInNeeded, sync.status.value)
        assertEquals(0, auth.interactiveRequests)
        assertTrue(api.calls.isEmpty())
        assertEquals(0, scheduler.retries)
    }

    @Test
    fun expiredTokenIsClearedAndRetriedSilentlyOnce() = runTest {
        api.rejectedTokens += "token-1"
        val sync = controller()

        sync.start()

        assertEquals(listOf("token-1"), auth.cleared)
        assertEquals("token-2", api.tokensSeen.last())
        assertIs<SyncStatus.UpToDate>(sync.status.value)
    }

    @Test
    fun tokenRejectedTwiceAsksForSignIn() = runTest {
        api.rejectedTokens += setOf("token-1", "token-2")
        val sync = controller()

        sync.start()

        assertEquals(SyncStatus.SignInNeeded, sync.status.value)
        assertEquals(listOf("token-1", "token-2"), auth.cleared)
    }

    @Test
    fun authorizationOfflineReportsOffline() = runTest {
        auth.silent = AuthOutcome.Failed(SyncMessages.OFFLINE, offline = true)
        val sync = controller()

        sync.start()

        assertEquals(SyncStatus.Failed(SyncMessages.OFFLINE), sync.status.value)
        assertEquals(1, scheduler.retries)
    }

    // First sync and merge

    @Test
    fun firstSyncCreatesTheSnapshotFromLocalData() = runTest {
        store.local = CloudSnapshot(positions = mapOf("d-1" to 30.0), completed = listOf("d-2"))
        val sync = controller()

        sync.start()

        assertEquals(listOf("list", "create"), api.calls)
        assertEquals(store.export(), api.only())
        assertEquals(1, scheduler.periodic)
        assertEquals(SyncStatus.UpToDate(0), sync.status.value)
    }

    @Test
    fun existingSnapshotIsMergedThenTheUnionIsPushed() = runTest {
        store.local = CloudSnapshot(positions = mapOf("d-1" to 30.0), bookmarks = listOf(bookmark("b-local")))
        api.seed(CloudSnapshot(positions = mapOf("d-1" to 10.0, "d-2" to 100.0), bookmarks = listOf(bookmark("b-remote"))))
        val sync = controller()

        sync.start()

        assertEquals(mapOf("d-1" to 30.0, "d-2" to 100.0), store.local.positions.toSortedMap())
        val remote = api.only()
        assertEquals(mapOf("d-1" to 30.0, "d-2" to 100.0), remote.positions)
        assertEquals(listOf("b-local", "b-remote"), remote.bookmarks.map { it.id })
        assertEquals(listOf("list", "download", "get", "update"), api.calls)
    }

    @Test
    fun remoteThatAlreadyHasEverythingIsPulledWithoutPushing() = runTest {
        api.seed(CloudSnapshot(positions = mapOf("d-1" to 50.0), completed = listOf("d-9")))
        val sync = controller()

        sync.start()

        assertEquals(mapOf("d-1" to 50.0), store.local.positions)
        assertEquals(listOf("list", "download"), api.calls)
    }

    @Test
    fun unchangedVersionSkipsTheDownload() = runTest {
        api.seed(CloudSnapshot(positions = mapOf("d-1" to 50.0)))
        val sync = controller()
        sync.start()
        api.calls.clear()

        sync.syncNow()

        assertEquals(listOf("list"), api.calls)
    }

    @Test
    fun anotherDevicesNewerWriteIsDownloadedAndMerged() = runTest {
        val file = api.seed(CloudSnapshot(positions = mapOf("d-1" to 50.0)))
        val sync = controller()
        sync.start()

        api.writeFromOtherDevice(file.id, CloudSnapshot(positions = mapOf("d-1" to 50.0, "d-3" to 5.0)))
        sync.syncNow()

        assertEquals(5.0, store.local.positions["d-3"])
    }

    @Test
    fun duplicateFilesFromASimultaneousFirstSyncAreFoldedIntoTheOldest() = runTest {
        val oldest = api.seed(CloudSnapshot(completed = listOf("a")))
        api.seed(CloudSnapshot(completed = listOf("b")))
        val sync = controller()

        sync.start()

        assertEquals(listOf(oldest.id), api.files.keys.toList())
        assertEquals(listOf("a", "b"), api.only().completed)
        assertEquals(listOf("a", "b"), store.local.completed.sorted())
    }

    @Test
    fun unreadableSnapshotIsOverwritten() = runTest {
        api.seedRaw("not json")
        store.local = CloudSnapshot(completed = listOf("d-1"))
        val sync = controller()

        sync.start()

        assertEquals(listOf("d-1"), api.only().completed)
        assertIs<SyncStatus.UpToDate>(sync.status.value)
    }

    @Test
    fun snapshotDeletedDuringARoundIsRecreated() = runTest {
        val file = api.seed(CloudSnapshot(completed = listOf("a")))
        store.local = CloudSnapshot(completed = listOf("b"))
        api.beforeGetFile = {
            api.files.remove(file.id)
            api.beforeGetFile = null
        }
        val sync = controller()

        sync.start()

        assertEquals(listOf("a", "b"), api.only().completed)
        assertEquals(1, api.count("create"))
    }

    // Conflicts

    @Test
    fun writeBetweenReadAndPushIsMergedOnRetry() = runTest {
        val file = api.seed(CloudSnapshot(completed = listOf("a")))
        store.local = CloudSnapshot(completed = listOf("local"))
        api.beforeGetFile = {
            api.writeFromOtherDevice(file.id, CloudSnapshot(completed = listOf("a", "other")))
            api.beforeGetFile = null
        }
        val sync = controller()

        sync.start()

        assertEquals(listOf("a", "local", "other"), api.only().completed)
        assertEquals(2, api.count("list"))
        assertEquals(1, api.count("update"))
        assertIs<SyncStatus.UpToDate>(sync.status.value)
    }

    @Test
    fun endlessConflictsFailAndScheduleARetry() = runTest {
        val file = api.seed(CloudSnapshot(completed = listOf("a")))
        store.local = CloudSnapshot(completed = listOf("local"))
        var other = 0
        api.beforeGetFile = { api.writeFromOtherDevice(file.id, CloudSnapshot(completed = listOf("o${other++}"))) }
        val sync = controller()

        sync.start()

        assertEquals(DriveSyncEngine.MAX_ATTEMPTS, api.count("list"))
        assertEquals(0, api.count("update"))
        assertEquals(SyncStatus.Failed(SyncMessages.DRIVE_UNAVAILABLE), sync.status.value)
        assertEquals(1, scheduler.retries)
    }

    // Offline and errors

    @Test
    fun offlineReportsTheStateKeepsChangesAndPushesWhenTheWorkerRuns() = runTest {
        val sync = controller()
        sync.start()
        runCurrent()
        api.failure = offline

        localChange { it.copy(completed = listOf("d-1")) }
        advanceTimeBy(30_001)

        assertEquals(SyncStatus.Failed(SyncMessages.OFFLINE), sync.status.value)
        assertEquals(1, scheduler.retries)

        api.failure = null
        assertEquals(DriveSyncController.RoundResult.DONE, sync.runFromWorker())
        assertEquals(listOf("d-1"), api.only().completed)
        assertIs<SyncStatus.UpToDate>(sync.status.value)
    }

    @Test
    fun workerRoundOfflineAsksForRetryWithoutSchedulingAnother() = runTest {
        api.failure = offline
        val sync = controller()

        assertEquals(DriveSyncController.RoundResult.RETRY, sync.runFromWorker())
        assertEquals(0, scheduler.retries)
    }

    @Test
    fun driveApiDisabledIsNotRetried() = runTest {
        api.failure = DriveException.Forbidden("accessNotConfigured", "Drive API has not been used")
        val sync = controller()

        sync.start()

        assertEquals(SyncStatus.Failed(SyncMessages.CANNOT_CONNECT), sync.status.value)
        assertEquals(0, scheduler.retries)
    }

    // Push timing

    @Test
    fun aBurstOfLocalChangesIsPushedOnceAfterTheGatherDelay() = runTest {
        val sync = controller()
        sync.start()
        runCurrent()
        advanceTimeBy(31_000)

        localChange { it.copy(completed = listOf("a")) }
        advanceTimeBy(1_000)
        localChange { it.copy(completed = listOf("a", "b")) }
        advanceTimeBy(1_000)
        localChange { it.copy(completed = listOf("a", "b", "c")) }

        advanceTimeBy(2_999)
        assertEquals(0, api.count("update"))
        advanceTimeBy(2)
        assertEquals(1, api.count("update"))
        assertEquals(listOf("a", "b", "c"), api.only().completed)

        advanceTimeBy(60_000)
        assertEquals(1, api.count("update"))
    }

    @Test
    fun pushesDuringPlaybackAreAtLeastTheMinimumIntervalApart() = runTest {
        val sync = controller()
        sync.start()
        runCurrent()
        // The launch round at 0 s counts, so a change at 1 s waits until 30 s.
        advanceTimeBy(1_000)
        localChange { it.copy(positions = mapOf("d-1" to 10.0)) }

        advanceTimeBy(28_999)
        assertEquals(0, api.count("update"))
        advanceTimeBy(2)
        assertEquals(1, api.count("update"))

        localChange { it.copy(positions = mapOf("d-1" to 20.0)) }
        advanceTimeBy(29_998)
        assertEquals(1, api.count("update"))
        advanceTimeBy(2)
        assertEquals(2, api.count("update"))
        assertEquals(mapOf("d-1" to 20.0), api.only().positions)
    }

    @Test
    fun changesFromAMergeDoNotPushTheSameDataBack() = runTest {
        api.seed(CloudSnapshot(completed = listOf("remote")))
        val sync = controller()
        sync.start()
        runCurrent()
        api.calls.clear()

        // The repositories announce the merged-in data like any other change.
        check(changes.tryEmit(Unit))
        advanceTimeBy(60_000)

        assertEquals(listOf("list"), api.calls)
    }

    // App lifecycle

    @Test
    fun foregroundPullsUnlessARoundJustRan() = runTest {
        val sync = controller()
        sync.start()
        runCurrent()
        api.calls.clear()

        visibility.emit(true)
        runCurrent()
        assertTrue(api.calls.isEmpty())

        advanceTimeBy(30_000)
        visibility.emit(true)
        runCurrent()
        assertEquals(listOf("list"), api.calls)
    }

    @Test
    fun backgroundHandsUnsentChangesToWorkManager() = runTest {
        val sync = controller()
        sync.start()
        runCurrent()

        visibility.emit(false)
        runCurrent()
        assertEquals(0, scheduler.retries)

        localChange { it.copy(completed = listOf("d-1")) }
        runCurrent()
        visibility.emit(false)
        runCurrent()
        assertEquals(1, scheduler.retries)
    }

    // Sign out and disconnect

    @Test
    fun signOutStopsSyncAndForgetsTheToken() = runTest {
        val sync = controller()
        sync.start()
        runCurrent()
        api.calls.clear()

        sync.signOut()
        localChange { it.copy(completed = listOf("d-1")) }
        advanceTimeBy(120_000)
        sync.syncNow()

        assertEquals(SyncStatus.SignInNeeded, sync.status.value)
        assertEquals(false, prefs.enabled)
        assertEquals(1, scheduler.cancels)
        assertEquals(listOf("token-1"), auth.cleared)
        assertTrue(api.calls.isEmpty())
    }

    @Test
    fun disconnectRevokesTheGrantForTheRememberedAccount() = runTest {
        val sync = controller()
        sync.start()

        assertTrue(sync.disconnect())

        assertEquals(listOf<String?>("listener@example.com"), auth.revoked)
        assertNull(prefs.accountName)
        assertEquals(SyncStatus.SignInNeeded, sync.status.value)
        assertEquals(1, api.files.size)
    }

    @Test
    fun reconnectingAfterSignOutSyncsAgain() = runTest {
        val sync = controller()
        sync.start()
        sync.signOut()
        store.local = CloudSnapshot(completed = listOf("later"))

        sync.requestAuthorization()

        assertTrue(prefs.enabled)
        assertEquals(listOf("later"), api.only().completed)
    }
}
