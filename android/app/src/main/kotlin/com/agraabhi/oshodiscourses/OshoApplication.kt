package com.agraabhi.oshodiscourses

import android.app.Application

/** Owns the process-wide [AppContainer], so the media service and widgets share one graph. */
class OshoApplication : Application() {
    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        container = AppContainer(this)
    }
}
