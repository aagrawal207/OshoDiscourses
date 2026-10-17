package com.agraabhi.oshodiscourses.transcript

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import okhttp3.OkHttpClient
import java.io.File

/** Builds the Android [TranscriptService] for `AppContainer`. */
object Transcripts {
    fun create(context: Context, client: OkHttpClient): TranscriptService {
        val app = context.applicationContext
        val fetcher = TranscriptFetcher(client, isCellularOnly = cellularCheck(app))
        return TranscriptService(
            directory = File(app.noBackupFilesDir, TranscriptService.DIRECTORY_NAME),
            fetchHTML = fetcher::fetchDescriptionHTML,
        )
    }

    /** True when the active network rides on cellular, the case iOS `allowsCellularAccess = false` refuses. */
    fun cellularCheck(context: Context): () -> Boolean {
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
        return {
            val capabilities = connectivity?.activeNetwork?.let(connectivity::getNetworkCapabilities)
            capabilities != null && capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)
        }
    }
}
