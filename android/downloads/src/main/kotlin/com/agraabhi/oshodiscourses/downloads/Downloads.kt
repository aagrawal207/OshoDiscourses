package com.agraabhi.oshodiscourses.downloads

import android.content.Context
import android.content.pm.ApplicationInfo
import android.os.storage.StorageManager
import com.agraabhi.oshodiscourses.core.domain.settings.SettingsRepository
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptRepository
import com.agraabhi.oshodiscourses.core.model.CatalogRepository
import kotlinx.coroutines.CoroutineScope
import okhttp3.OkHttpClient
import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit

/** Builds the process-wide [DownloadEngine] with its Android collaborators. Create one per process. */
object Downloads {
    /** Intent extra for debug builds, the Android form of iOS `-debugDownloadNetwork`. */
    const val DEBUG_NETWORK_EXTRA: String = "debugDownloadNetwork"

    fun createEngine(
        context: Context,
        catalog: CatalogRepository,
        settings: SettingsRepository,
        transcripts: TranscriptRepository,
        scope: CoroutineScope,
        okHttpClient: OkHttpClient? = null,
    ): DownloadEngine {
        val app = context.applicationContext
        val client = (okHttpClient?.newBuilder() ?: OkHttpClient.Builder())
            .connectTimeout(30, TimeUnit.SECONDS)
            // A backstop behind the stall watchdog, which owns the 120 s rule.
            .readTimeout(DownloadRules.STALL_THRESHOLD_MILLIS, TimeUnit.MILLISECONDS)
            .retryOnConnectionFailure(true)
            .build()
        return DownloadEngine(
            store = DownloadStore(filesDir = app.filesDir, partialDir = File(app.noBackupFilesDir, "downloads-partial")),
            catalog = catalog,
            settings = settings,
            transcripts = transcripts,
            networkMonitor = AndroidNetworkMonitor(app),
            scheduler = AndroidTransferScheduler(app),
            speedStore = SharedPreferencesSpeedStore(app),
            httpClient = client,
            transfer = HttpTransfer(freeSpace = { dir -> allocatableBytes(app, dir) }),
            isNearOshoworld = DeviceRegion(app)::isNearOshoworld,
            scope = scope,
            debugFeaturesEnabled = app.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0,
        )
    }

    /** Counts cache the system would clear for us, so a nearly full phone is not refused too early. */
    private fun allocatableBytes(context: Context, dir: File): Long {
        val storage = context.getSystemService(StorageManager::class.java) ?: return dir.usableSpace
        return try {
            storage.getAllocatableBytes(storage.getUuidForPath(dir))
        } catch (e: IOException) {
            dir.usableSpace
        }
    }
}
