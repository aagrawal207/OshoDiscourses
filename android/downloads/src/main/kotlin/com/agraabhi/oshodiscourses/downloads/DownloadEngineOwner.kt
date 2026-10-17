package com.agraabhi.oshodiscourses.downloads

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/** Implemented by the `Application`, so the system-created job service and worker reach the one engine. */
interface DownloadEngineOwner {
    val downloadEngine: DownloadEngine

    companion object {
        fun from(context: Context): DownloadEngine? = (context.applicationContext as? DownloadEngineOwner)?.downloadEngine
    }
}

/** The notification's Cancel action. */
class DownloadNotificationReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_CANCEL) return
        val id = intent.getStringExtra(EXTRA_DISCOURSE_ID) ?: return
        val engine = DownloadEngineOwner.from(context) ?: return
        val pending = goAsync()
        CoroutineScope(SupervisorJob() + Dispatchers.Default).launch {
            try {
                engine.cancel(id)
            } finally {
                pending.finish()
            }
        }
    }

    companion object {
        const val ACTION_CANCEL: String = "com.agraabhi.oshodiscourses.downloads.CANCEL"
        const val EXTRA_DISCOURSE_ID: String = "discourseID"
    }
}
