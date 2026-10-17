package com.agraabhi.oshodiscourses.downloads

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadState

/** The progress notification every host shows; one id so two hosts never show two entries. */
class DownloadNotifications(context: Context) {
    private val context = context.applicationContext

    fun ensureChannel() {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(CHANNEL_ID, context.getString(R.string.downloads_channel_name), NotificationManager.IMPORTANCE_LOW)
        channel.description = context.getString(R.string.downloads_channel_description)
        channel.setShowBadge(false)
        manager.createNotificationChannel(channel)
    }

    fun build(active: DownloadEngine.ActiveTransfer?): Notification {
        ensureChannel()
        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_download)
            .setContentTitle(active?.title ?: context.getString(R.string.downloads_notification_title))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
        context.packageManager.getLaunchIntentForPackage(context.packageName)?.let { launch ->
            builder.setContentIntent(PendingIntent.getActivity(context, 0, launch, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
        }
        if (active == null) return builder.setContentText(context.getString(R.string.downloads_notification_downloading)).build()

        val status = when (val state = active.state) {
            DownloadState.WaitingForWifi -> context.getString(R.string.downloads_notification_waiting_wifi)
            DownloadState.WaitingForConnection -> context.getString(R.string.downloads_notification_waiting_connection)
            is DownloadState.Downloading -> {
                val known = state.totalBytes != null && state.totalBytes!! > 0
                builder.setProgress(100, (state.progress * 100).toInt(), !known)
                context.getString(R.string.downloads_notification_downloading)
            }
            else -> context.getString(R.string.downloads_notification_downloading)
        }
        val queued = if (active.queuedBehind > 0) {
            context.resources.getQuantityString(R.plurals.downloads_notification_queued, active.queuedBehind, active.queuedBehind)
        } else {
            null
        }
        builder.setContentText(listOfNotNull(status, queued).joinToString(" · "))
        val cancel = Intent(context, DownloadNotificationReceiver::class.java)
            .setAction(DownloadNotificationReceiver.ACTION_CANCEL)
            .putExtra(DownloadNotificationReceiver.EXTRA_DISCOURSE_ID, active.discourseID)
        builder.addAction(
            0,
            context.getString(R.string.downloads_notification_cancel),
            PendingIntent.getBroadcast(context, 1, cancel, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT),
        )
        return builder.build()
    }

    /** Coarse key so the notification refreshes on whole-percent and state changes only. */
    fun refreshKey(active: DownloadEngine.ActiveTransfer?): Any? = active?.let {
        val percent = (it.state as? DownloadState.Downloading)?.let { s -> (s.progress * 100).toInt() }
        listOf(it.discourseID, it.state.javaClass, percent, it.queuedBehind)
    }

    companion object {
        const val CHANNEL_ID: String = "downloads"
        const val NOTIFICATION_ID: Int = 0x05D1
    }
}
