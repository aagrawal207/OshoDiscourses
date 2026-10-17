package com.agraabhi.oshodiscourses.downloads

import android.app.job.JobInfo
import android.app.job.JobScheduler
import android.content.ComponentName
import android.content.Context
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import java.util.concurrent.TimeUnit

/** Arranges for a host process to call [DownloadEngine.runQueue] while transfers are queued. */
interface TransferScheduler {
    /**
     * Makes sure a host will run the queue under the current cellular rule. [replace] restarts a
     * running host so a changed rule takes effect; otherwise an existing host is kept.
     */
    fun schedule(allowCellular: Boolean, estimatedBytes: Long, replace: Boolean)

    /** Drops a host that has not started, once nothing is left to transfer. */
    fun cancelPending()
}

/**
 * Android 14+ uses a user-initiated job, which avoids Android 15's six-hour dataSync limit. It can only
 * be scheduled while the app is visible; otherwise, and on older releases, a WorkManager worker runs.
 */
class AndroidTransferScheduler(context: Context) : TransferScheduler {
    private val context = context.applicationContext

    override fun schedule(allowCellular: Boolean, estimatedBytes: Long, replace: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE && scheduleUserInitiated(allowCellular, estimatedBytes, replace)) {
            if (replace) WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME)
            return
        }
        scheduleWorker(allowCellular, replace)
    }

    override fun cancelPending() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            context.getSystemService(JobScheduler::class.java)?.forNamespace(JOB_NAMESPACE)?.cancel(JOB_ID)
        }
        WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME)
        Log.i(TAG, "host cancelled")
    }

    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    private fun scheduleUserInitiated(allowCellular: Boolean, estimatedBytes: Long, replace: Boolean): Boolean {
        // Its own namespace keeps the id clear of the ids WorkManager assigns its jobs.
        val jobs = context.getSystemService(JobScheduler::class.java)?.forNamespace(JOB_NAMESPACE) ?: return false
        if (!replace && jobs.getPendingJob(JOB_ID) != null) return true
        val job = JobInfo.Builder(JOB_ID, ComponentName(context, DownloadJobService::class.java))
            .setUserInitiated(true)
            .setRequiredNetwork(networkRequest(allowCellular))
            .setEstimatedNetworkBytes(estimatedBytes, 0)
            .setPersisted(true)
            .build()
        return try {
            val scheduled = jobs.schedule(job) == JobScheduler.RESULT_SUCCESS
            Log.i(TAG, "host=job scheduled=$scheduled allowCellular=$allowCellular")
            scheduled
        } catch (e: RuntimeException) {
            // Not visible to the user, or the system refused; the worker takes over.
            Log.w(TAG, "host=job refused", e)
            false
        }
    }

    private fun scheduleWorker(allowCellular: Boolean, replace: Boolean) {
        val constraints = Constraints.Builder().apply {
            if (!allowCellular && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                setRequiredNetworkRequest(networkRequest(allowCellular = false), NetworkType.UNMETERED)
            } else {
                setRequiredNetworkType(if (allowCellular) NetworkType.CONNECTED else NetworkType.UNMETERED)
            }
        }.build()
        val request = OneTimeWorkRequestBuilder<DownloadWorker>()
            .setConstraints(constraints)
            .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            .setBackoffCriteria(BackoffPolicy.LINEAR, 30, TimeUnit.SECONDS)
            .build()
        val policy = if (replace) ExistingWorkPolicy.REPLACE else ExistingWorkPolicy.KEEP
        WorkManager.getInstance(context).enqueueUniqueWork(WORK_NAME, policy, request)
        Log.i(TAG, "host=worker policy=$policy allowCellular=$allowCellular")
    }

    companion object {
        const val JOB_ID: Int = 1
        const val JOB_NAMESPACE: String = "osho.downloads"
        const val WORK_NAME: String = "osho-downloads"

        /** Wi-Fi or Ethernet by transport, matching how [AndroidNetworkMonitor] tells Wi-Fi from mobile data. */
        fun networkRequest(allowCellular: Boolean): NetworkRequest = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .apply {
                if (!allowCellular) {
                    addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                    addTransportType(NetworkCapabilities.TRANSPORT_ETHERNET)
                }
            }
            .build()
    }
}

private const val TAG = "Downloads"
