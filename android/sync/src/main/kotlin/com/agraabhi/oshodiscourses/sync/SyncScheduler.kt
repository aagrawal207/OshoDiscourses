package com.agraabhi.oshodiscourses.sync

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit

/** Background sync jobs that outlive the process. */
internal interface SyncScheduler {
    /** The periodic pull and merge while the app is closed. */
    fun schedulePeriodic()

    /** A one-off round as soon as the network allows, for unpushed changes or a failed round. */
    fun scheduleRetry()

    fun cancelAll()
}

internal class WorkManagerSyncScheduler(context: Context) : SyncScheduler {
    private val appContext = context.applicationContext
    private val workManager: WorkManager get() = WorkManager.getInstance(appContext)
    private val online = Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()

    override fun schedulePeriodic() {
        val request = PeriodicWorkRequestBuilder<DriveSyncWorker>(PERIODIC_HOURS, TimeUnit.HOURS)
            .setConstraints(
                Constraints.Builder()
                    .setRequiredNetworkType(NetworkType.CONNECTED)
                    .setRequiresBatteryNotLow(true)
                    .build(),
            )
            .build()
        workManager.enqueueUniquePeriodicWork(PERIODIC_WORK, ExistingPeriodicWorkPolicy.KEEP, request)
    }

    override fun scheduleRetry() {
        val request = OneTimeWorkRequestBuilder<DriveSyncWorker>()
            .setConstraints(online)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, RETRY_BACKOFF_SECONDS, TimeUnit.SECONDS)
            .build()
        // KEEP: a retry already waiting for the network covers this one too.
        workManager.enqueueUniqueWork(RETRY_WORK, ExistingWorkPolicy.KEEP, request)
    }

    override fun cancelAll() {
        workManager.cancelUniqueWork(PERIODIC_WORK)
        workManager.cancelUniqueWork(RETRY_WORK)
    }

    companion object {
        const val PERIODIC_WORK: String = "drive-sync-periodic"
        const val RETRY_WORK: String = "drive-sync-retry"

        /** Launch and foreground already pull; this only catches other devices' changes while closed. */
        const val PERIODIC_HOURS: Long = 6
        const val RETRY_BACKOFF_SECONDS: Long = 30
    }
}

/** Runs one sync round on the process's [DriveSyncController], which `:app` builds at startup. */
class DriveSyncWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val controller = DriveSyncController.active ?: return Result.success()
        return when (controller.runFromWorker()) {
            DriveSyncController.RoundResult.RETRY ->
                if (runAttemptCount < MAX_RETRIES) Result.retry() else Result.success()
            DriveSyncController.RoundResult.DONE -> Result.success()
        }
    }

    private companion object {
        /** Past this, the next launch, foreground or periodic run tries again. */
        const val MAX_RETRIES = 5
    }
}
