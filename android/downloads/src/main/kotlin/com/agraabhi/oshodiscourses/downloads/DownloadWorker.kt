package com.agraabhi.oshodiscourses.downloads

import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationManagerCompat
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.flow.distinctUntilChangedBy
import kotlinx.coroutines.launch

/**
 * Host below Android 14, and the fallback when a job cannot be scheduled from the background. If the
 * system stops it (including Android 15's dataSync limit), WorkManager retries and Range resumes.
 */
class DownloadWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    private val notifications = DownloadNotifications(context)

    override suspend fun doWork(): Result {
        val engine = DownloadEngineOwner.from(applicationContext) ?: return Result.failure()
        try {
            setForeground(foregroundInfo(engine.activeTransfer.value))
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // Background start refused: run as ordinary work; a stop is retried and resumed.
            Log.w(TAG, "host=worker foreground refused", e)
        }
        Log.i(TAG, "host=worker started")
        val drained = coroutineScope {
            val updates = launch {
                engine.activeTransfer.distinctUntilChangedBy(notifications::refreshKey).conflate().collect { active ->
                    notify(active)
                    delay(NOTIFICATION_INTERVAL_MILLIS)
                }
            }
            try {
                engine.runQueue()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.e(TAG, "host=worker failed", e)
                false
            } finally {
                updates.cancel()
            }
        }
        Log.i(TAG, "host=worker finished drained=$drained")
        return if (drained) Result.success() else Result.retry()
    }

    override suspend fun getForegroundInfo(): ForegroundInfo =
        foregroundInfo(DownloadEngineOwner.from(applicationContext)?.activeTransfer?.value)

    private fun foregroundInfo(active: DownloadEngine.ActiveTransfer?): ForegroundInfo {
        val notification = notifications.build(active)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ForegroundInfo(DownloadNotifications.NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            ForegroundInfo(DownloadNotifications.NOTIFICATION_ID, notification)
        }
    }

    private fun notify(active: DownloadEngine.ActiveTransfer?) {
        val manager = NotificationManagerCompat.from(applicationContext)
        if (!manager.areNotificationsEnabled()) return
        try {
            manager.notify(DownloadNotifications.NOTIFICATION_ID, notifications.build(active))
        } catch (e: SecurityException) {
            Log.w(TAG, "notification refused", e)
        }
    }

    private companion object {
        const val NOTIFICATION_INTERVAL_MILLIS = 1_000L
    }
}

private const val TAG = "Downloads"
