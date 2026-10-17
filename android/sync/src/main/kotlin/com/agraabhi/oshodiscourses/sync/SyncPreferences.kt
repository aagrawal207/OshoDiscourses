package com.agraabhi.oshodiscourses.sync

import android.content.Context
import android.content.SharedPreferences

/** User-facing [com.agraabhi.oshodiscourses.core.domain.sync.SyncStatus.Failed] messages. */
object SyncMessages {
    const val OFFLINE: String = "You're offline. Sync resumes when you're connected."
    const val CANNOT_CONNECT: String = "Couldn't connect to Google Drive."
    const val DRIVE_UNAVAILABLE: String = "Google Drive is unavailable. Sync will try again later."
}

/** Opt-in state. Android needs explicit consent, so sync stays off until the user connects. */
internal interface SyncPreferences {
    var enabled: Boolean

    /** Needed to revoke the grant on disconnect. */
    var accountName: String?
}

internal class SharedSyncPreferences(context: Context) : SyncPreferences {
    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences(FILE_NAME, Context.MODE_PRIVATE)

    override var enabled: Boolean
        get() = prefs.getBoolean(KEY_ENABLED, false)
        set(value) = prefs.edit().putBoolean(KEY_ENABLED, value).apply()

    override var accountName: String?
        get() = prefs.getString(KEY_ACCOUNT, null)
        set(value) = prefs.edit().putString(KEY_ACCOUNT, value).apply()

    private companion object {
        const val FILE_NAME = "drive_sync"
        const val KEY_ENABLED = "enabled"
        const val KEY_ACCOUNT = "accountName"
    }
}
