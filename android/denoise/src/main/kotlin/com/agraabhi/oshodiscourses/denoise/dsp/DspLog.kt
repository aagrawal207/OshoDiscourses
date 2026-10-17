package com.agraabhi.oshodiscourses.denoise.dsp

import android.util.Log

/** Local setup and status logs only; never called per audio callback. */
internal object DspLog {
    private const val PREFIX = "OshoDenoise."

    // JVM unit tests run against the stub android.jar, where Log throws.
    private val available: Boolean by lazy {
        try {
            Log.isLoggable(PREFIX, Log.INFO)
            true
        } catch (_: RuntimeException) {
            false
        }
    }

    fun info(category: String, message: String) {
        if (available) Log.i(PREFIX + category, message)
    }

    fun error(category: String, message: String) {
        if (available) Log.e(PREFIX + category, message)
    }
}
