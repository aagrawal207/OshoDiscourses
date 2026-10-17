package com.agraabhi.oshodiscourses.downloads

import android.content.Context
import android.content.SharedPreferences
import androidx.core.content.edit
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadSource

/** Measured bytes per second for each server, kept across launches (iOS `UserDefaults` key). */
interface SourceSpeedStore {
    fun load(): Map<DownloadSource, Double>

    fun save(speeds: Map<DownloadSource, Double>)
}

class SharedPreferencesSpeedStore(private val preferences: SharedPreferences) : SourceSpeedStore {
    constructor(context: Context) : this(context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE))

    override fun load(): Map<DownloadSource, Double> =
        DownloadSourcePolicy.decodeSpeeds(runCatching { preferences.getString(DownloadSourcePolicy.SPEEDS_KEY, null) }.getOrNull())

    override fun save(speeds: Map<DownloadSource, Double>) {
        preferences.edit { putString(DownloadSourcePolicy.SPEEDS_KEY, DownloadSourcePolicy.encodeSpeeds(speeds)) }
    }

    companion object {
        const val PREFERENCES_NAME: String = "downloads"
    }
}

class InMemorySpeedStore(private var speeds: Map<DownloadSource, Double> = emptyMap()) : SourceSpeedStore {
    override fun load(): Map<DownloadSource, Double> = speeds

    override fun save(speeds: Map<DownloadSource, Double>) {
        this.speeds = speeds
    }
}
