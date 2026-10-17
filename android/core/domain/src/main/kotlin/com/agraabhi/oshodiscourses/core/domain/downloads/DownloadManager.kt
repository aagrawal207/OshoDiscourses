package com.agraabhi.oshodiscourses.core.domain.downloads

import kotlinx.coroutines.flow.StateFlow

/**
 * Background downloads that survive app switch, lock and process death (iOS `DownloadService`).
 *
 * One transfer runs at a time so it gets the server's full speed; the rest wait as
 * [DownloadState.Queued]. Each transfer tries the nearer server first and falls back to the
 * other (`DownloadSource`). Files live under the app's files dir as
 * `Osho Discourses/<Series>/<Series> - #N.mp3`, tracked by a JSON manifest. Committing a file
 * also prefetches its transcript; deleting it removes the cached transcript.
 */
interface DownloadManager {
    /** Every discourse that is not [DownloadState.NotDownloaded]; absent keys are not downloaded. */
    val states: StateFlow<Map<String, DownloadState>>

    /** Discourses whose file is on disk. */
    val downloadedIDs: StateFlow<Set<String>>

    /** Every discourse ever downloaded (monotonic, synced), for quick re-download. */
    val downloadHistory: StateFlow<Set<String>>

    val network: StateFlow<DownloadNetwork>

    /** Why active downloads are not moving, when the reason is the network; drives the notice. */
    val waitingReason: StateFlow<WaitingReason?>

    /** Total bytes of downloaded audio, for the storage meter. */
    val storageUsedBytes: StateFlow<Long>

    fun state(discourseID: String): DownloadState = states.value[discourseID] ?: DownloadState.NotDownloaded

    /** Local file URI of a downloaded discourse, or null. */
    fun localFileURI(discourseID: String): String?

    /** Queues a download; no-op when already downloaded, queued or running. */
    suspend fun enqueue(discourseID: String)

    /** Queues several in the given order, e.g. "Download All" on a series page. */
    suspend fun enqueueAll(discourseIDs: List<String>)

    suspend fun cancel(discourseID: String)

    suspend fun delete(discourseID: String)

    suspend fun deleteDownloads(discourseIDs: List<String>)

    suspend fun deleteSeries(seriesID: String)

    suspend fun deleteAll()

    /** Turns on `allowCellularDownloads` and moves waiting transfers onto mobile data. */
    suspend fun useMobileData()

    /** Bytes per downloaded discourse. */
    suspend fun downloadedSizes(): Map<String, Long>

    /** Running transfer first, then queued ones in request order. */
    fun inProgressIDs(): List<String>

    /** Union-merges another device's history; returns true if local history changed. */
    suspend fun mergeSyncedDownloadHistory(incoming: List<String>): Boolean

    suspend fun forgetDownloadHistory(discourseIDs: List<String>)

    fun syncedDownloadHistory(): List<String>
}

/** Per-discourse download state. */
sealed interface DownloadState {
    data object NotDownloaded : DownloadState

    /** Waiting its turn behind another transfer. */
    data object Queued : DownloadState

    /** Running, but on mobile data with `allowCellularDownloads` off. */
    data object WaitingForWifi : DownloadState

    /** Running, but there is no network. */
    data object WaitingForConnection : DownloadState

    data class Downloading(
        /** 0..1; 0 while the size is unknown. */
        val progress: Double,
        val bytesDownloaded: Long,
        val totalBytes: Long?,
    ) : DownloadState

    data object Downloaded : DownloadState

    data class Failed(val error: DownloadError) : DownloadState

    /** Occupies a slot: queued, waiting or transferring. */
    val isActive: Boolean
        get() = this is Queued || this is WaitingForWifi || this is WaitingForConnection || this is Downloading
}

/** A failure with a message the UI shows as-is (iOS `DownloadService.DownloadError`). */
sealed interface DownloadError {
    val message: String

    data object WifiOnly : DownloadError {
        override val message = "Wi-Fi only. Turn on \"Download over Cellular\" in Settings."
    }

    data object NotFound : DownloadError {
        override val message = "Not available on the server (404)."
    }

    data class ServerError(val code: Int) : DownloadError {
        override val message get() = "Server error (HTTP $code)."
    }

    data object NotAudio : DownloadError {
        override val message = "Server returned a web page, not audio."
    }

    data object Offline : DownloadError {
        override val message = "No internet connection."
    }

    data object DiskFull : DownloadError {
        override val message = "Not enough storage on your device."
    }

    data object SaveFailed : DownloadError {
        override val message = "Downloaded, but couldn't be saved. Try again."
    }

    data object Stalled : DownloadError {
        override val message = "The download stopped responding. Check your connection and try again."
    }
}

/** What the current network allows downloads to do (iOS `DownloadNetwork`). */
enum class DownloadNetwork { UNRESTRICTED, CELLULAR_ONLY, OFFLINE }

/** iOS `DownloadService.WaitingReason`. */
enum class WaitingReason { WIFI, CONNECTION }

/** archive.org serves from US data centres; oshoworld.com from Delhi (iOS `DownloadSource`). */
enum class DownloadSource(val rawValue: String) { ARCHIVE("archive"), OSHOWORLD("oshoworld") }
