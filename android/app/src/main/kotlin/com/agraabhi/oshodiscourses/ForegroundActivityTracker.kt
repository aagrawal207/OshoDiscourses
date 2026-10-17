package com.agraabhi.oshodiscourses

import android.app.Activity
import android.app.Application
import android.os.Bundle
import androidx.activity.ComponentActivity
import java.lang.ref.WeakReference

/**
 * The activity billing sheets, the review card and Drive consent present on. Prefers the resumed
 * activity and falls back to a started one, so a permission dialog covering it does not hide it.
 */
class ForegroundActivityTracker(application: Application) {
    @Volatile private var resumed: WeakReference<ComponentActivity>? = null

    @Volatile private var started: WeakReference<ComponentActivity>? = null

    init {
        application.registerActivityLifecycleCallbacks(
            object : Application.ActivityLifecycleCallbacks {
                override fun onActivityStarted(activity: Activity) {
                    if (activity is ComponentActivity) started = WeakReference(activity)
                }

                override fun onActivityResumed(activity: Activity) {
                    if (activity is ComponentActivity) resumed = WeakReference(activity)
                }

                override fun onActivityPaused(activity: Activity) {
                    if (resumed?.get() === activity) resumed = null
                }

                override fun onActivityStopped(activity: Activity) {
                    if (started?.get() === activity) started = null
                }

                override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit

                override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit

                override fun onActivityDestroyed(activity: Activity) = Unit
            },
        )
    }

    /** The foreground activity, or null while the app is in the background. */
    fun current(): ComponentActivity? = resumed?.get()?.takeUnless { it.isFinishing } ?: started?.get()?.takeUnless { it.isFinishing }
}
