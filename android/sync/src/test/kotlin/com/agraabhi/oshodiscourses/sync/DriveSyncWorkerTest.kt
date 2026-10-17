package com.agraabhi.oshodiscourses.sync

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.work.ListenableWorker
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.testing.TestListenableWorkerBuilder
import androidx.work.testing.WorkManagerTestInitHelper
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36])
class DriveSyncWorkerTest {
    private val context: Context = ApplicationProvider.getApplicationContext()
    private val api = FakeDriveApi()

    @Before
    fun setUp() {
        DriveSyncController.active = null
        WorkManagerTestInitHelper.initializeTestWorkManager(context)
    }

    @After
    fun tearDown() {
        DriveSyncController.active = null
    }

    private fun TestScope.controller() = DriveSyncController(
        store = FakeSnapshotStore(),
        api = api,
        authorizer = FakeAuthorizer(),
        preferences = InMemorySyncPreferences(enabled = true),
        scheduler = FakeScheduler(),
        scope = backgroundScope,
        localChanges = emptyFlow(),
        appVisibility = emptyFlow(),
        clock = { testScheduler.currentTime },
    )

    private suspend fun runWorker(): ListenableWorker.Result =
        TestListenableWorkerBuilder<DriveSyncWorker>(context).build().doWork()

    @Test
    fun workerWithoutAControllerSucceeds() = runTest {
        assertEquals(ListenableWorker.Result.success(), runWorker())
    }

    @Test
    fun workerRunsARoundOnTheActiveController() = runTest {
        controller()

        assertEquals(ListenableWorker.Result.success(), runWorker())
        assertEquals(1, api.files.size)
    }

    @Test
    fun workerAsksForRetryWhenOffline() = runTest {
        controller()
        api.failure = offline

        assertEquals(ListenableWorker.Result.retry(), runWorker())
    }

    @Test
    fun schedulerEnqueuesUniquePeriodicAndRetryWorkAndCancelsBoth() {
        val scheduler = WorkManagerSyncScheduler(context)
        val workManager = WorkManager.getInstance(context)

        scheduler.schedulePeriodic()
        scheduler.schedulePeriodic()
        scheduler.scheduleRetry()
        scheduler.scheduleRetry()

        val periodic = workManager.getWorkInfosForUniqueWork(WorkManagerSyncScheduler.PERIODIC_WORK).get()
        val retry = workManager.getWorkInfosForUniqueWork(WorkManagerSyncScheduler.RETRY_WORK).get()
        assertEquals(1, periodic.size)
        assertEquals(1, retry.size)

        scheduler.cancelAll()

        val all = workManager.getWorkInfosForUniqueWork(WorkManagerSyncScheduler.PERIODIC_WORK).get() +
            workManager.getWorkInfosForUniqueWork(WorkManagerSyncScheduler.RETRY_WORK).get()
        assertTrue(all.all { it.state == WorkInfo.State.CANCELLED })
    }

    @Test
    fun preferencesPersistOptInAndAccount() {
        val prefs = SharedSyncPreferences(context)
        assertEquals(false, prefs.enabled)
        assertNull(prefs.accountName)

        prefs.enabled = true
        prefs.accountName = "listener@example.com"

        val reread = SharedSyncPreferences(context)
        assertEquals(true, reread.enabled)
        assertEquals("listener@example.com", reread.accountName)
    }
}
