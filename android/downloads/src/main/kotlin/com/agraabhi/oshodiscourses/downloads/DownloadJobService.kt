package com.agraabhi.oshodiscourses.downloads

import android.annotation.SuppressLint
import android.app.job.JobParameters
import android.app.job.JobService
import android.os.Build
import android.util.Log
import androidx.annotation.RequiresApi
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.flow.distinctUntilChangedBy
import kotlinx.coroutines.launch
import java.util.concurrent.ConcurrentHashMap

/**
 * Android 14+ host: a user-initiated data transfer job. The system may stop it (constraint
 * lost, thermal); returning true from [onStopJob] reschedules it and the transfer resumes by Range.
 */
@SuppressLint("SpecifyJobSchedulerIdRange") // Jobs live in their own namespace; see AndroidTransferScheduler.
class DownloadJobService : JobService() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val running = ConcurrentHashMap<Int, Job>()

    override fun onStartJob(params: JobParameters): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return false
        val engine = DownloadEngineOwner.from(this) ?: run {
            Log.w(TAG, "host=job no engine; the Application must implement DownloadEngineOwner")
            return false
        }
        start(params, engine)
        return true
    }

    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    private fun start(params: JobParameters, engine: DownloadEngine) {
        val notifications = DownloadNotifications(this)
        // Must be posted promptly after onStartJob, before any transfer work.
        setNotification(
            params,
            DownloadNotifications.NOTIFICATION_ID,
            notifications.build(engine.activeTransfer.value),
            JOB_END_NOTIFICATION_POLICY_REMOVE,
        )
        Log.i(TAG, "host=job started")
        running[params.jobId] = scope.launch {
            val updates = launch {
                var estimated = engine.estimatedQueueBytes
                engine.activeTransfer.distinctUntilChangedBy(notifications::refreshKey).conflate().collect { active ->
                    setNotification(params, DownloadNotifications.NOTIFICATION_ID, notifications.build(active), JOB_END_NOTIFICATION_POLICY_REMOVE)
                    val now = engine.estimatedQueueBytes
                    // A queue that grew mid-job needs a bigger budget, or the system may end the job early.
                    if (now > estimated) {
                        estimated = now
                        runCatching { updateEstimatedNetworkBytes(params, now, 0) }
                    }
                    delay(NOTIFICATION_INTERVAL_MILLIS)
                }
            }
            val drained = try {
                engine.runQueue()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.e(TAG, "host=job failed", e)
                false
            } finally {
                updates.cancel()
            }
            running.remove(params.jobId)
            Log.i(TAG, "host=job finished drained=$drained")
            jobFinished(params, !drained)
        }
    }

    override fun onStopJob(params: JobParameters): Boolean {
        val reason = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) params.stopReason else -1
        Log.i(TAG, "host=job stopped reason=$reason")
        running.remove(params.jobId)?.cancel()
        return true
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    private companion object {
        const val NOTIFICATION_INTERVAL_MILLIS = 1_000L
    }
}

private const val TAG = "Downloads"
