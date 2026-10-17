package com.agraabhi.oshodiscourses

import android.app.Application
import android.os.SystemClock
import android.util.Log
import com.agraabhi.oshodiscourses.downloads.DownloadEngine
import com.agraabhi.oshodiscourses.downloads.DownloadEngineOwner
import com.agraabhi.oshodiscourses.playback.PlaybackEngine
import com.agraabhi.oshodiscourses.playback.PlaybackEngineProvider

/**
 * Owns the process-wide [AppContainer], so the activity and the system-created media service,
 * download job and sync worker share one graph, whichever of them starts the process.
 */
class OshoApplication : Application(), DownloadEngineOwner, PlaybackEngineProvider {
    lateinit var container: AppContainer
        private set

    override val downloadEngine: DownloadEngine get() = container.downloadEngine

    override val playbackEngine: PlaybackEngine get() = container.playbackEngine

    override fun onCreate() {
        super.onCreate()
        val started = SystemClock.elapsedRealtime()
        container = AppContainer(this)
        container.start()
        Log.i(TAG, "outcome=container_ready ms=${SystemClock.elapsedRealtime() - started}")
    }

    private companion object {
        const val TAG = "Startup"
    }
}
