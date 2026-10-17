package com.agraabhi.oshodiscourses

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.edit
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadManager

/**
 * Asks for `POST_NOTIFICATIONS` (Android 13+) the first time the listener starts a download, so
 * the transfer's progress notification can show. Asked once; Settings remains the way back.
 */
class NotificationPermissionPrompt(
    private val context: Context,
    private val activity: () -> android.app.Activity?,
) {
    private val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)

    fun requestIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return
        if (preferences.getBoolean(KEY_ASKED, false)) return
        val host = activity() ?: return
        preferences.edit { putBoolean(KEY_ASKED, true) }
        host.runOnUiThread { ActivityCompat.requestPermissions(host, arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_CODE) }
    }

    private companion object {
        const val PREFERENCES = "app_prompts"
        const val KEY_ASKED = "notifications.askedAtFirstDownload"
        const val REQUEST_CODE = 41
    }
}

/** The screens' [DownloadManager]: a listener-started download first offers the notification prompt. */
class PromptingDownloadManager(
    private val engine: DownloadManager,
    private val prompt: NotificationPermissionPrompt,
) : DownloadManager by engine {
    override suspend fun enqueue(discourseID: String) {
        prompt.requestIfNeeded()
        engine.enqueue(discourseID)
    }

    override suspend fun enqueueAll(discourseIDs: List<String>) {
        prompt.requestIfNeeded()
        engine.enqueueAll(discourseIDs)
    }
}
