package com.agraabhi.oshodiscourses.downloads

import android.system.ErrnoException
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadError
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadNetwork
import com.agraabhi.oshodiscourses.core.domain.downloads.WaitingReason
import java.io.IOException
import kotlin.coroutines.cancellation.CancellationException

/** A failure that ends one source attempt with a message the UI shows as-is. */
class DownloadException(val error: DownloadError, cause: Throwable? = null) : IOException(error.message, cause)

/** Timeouts, resets and other transport failures: worth trying the other server, shown as offline. */
class TransportException(cause: IOException) : IOException(cause.message, cause)

/** Pure decisions behind the engine (iOS `DownloadService` static rules). */
object DownloadRules {
    /** A transfer that has not moved for this long is restarted, as on iOS. */
    const val STALL_THRESHOLD_MILLIS: Long = 120_000
    const val MAX_STALL_RESTARTS: Int = 2

    enum class StallAction { NONE, RESTART, ABANDON }

    fun stallAction(
        lastProgressMillis: Long,
        nowMillis: Long,
        restartsSoFar: Int,
        maxRestarts: Int,
        thresholdMillis: Long = STALL_THRESHOLD_MILLIS,
    ): StallAction {
        if (nowMillis - lastProgressMillis < thresholdMillis) return StallAction.NONE
        return if (restartsSoFar < maxRestarts) StallAction.RESTART else StallAction.ABANDON
    }

    fun shouldRestartStalledTransfer(
        lastProgressMillis: Long,
        nowMillis: Long,
        restartsSoFar: Int,
        thresholdMillis: Long = STALL_THRESHOLD_MILLIS,
        maxRestarts: Int = MAX_STALL_RESTARTS,
    ): Boolean = restartsSoFar < maxRestarts && nowMillis - lastProgressMillis >= thresholdMillis

    /** Fewer restarts when another server can be tried, so a frozen mirror does not hold the slot. */
    fun maxRestarts(hasFallback: Boolean): Int = if (hasFallback) 1 else MAX_STALL_RESTARTS

    /** Whether a finished file nobody is waiting for should be thrown away. */
    fun discardsUnclaimedFile(hasRow: Boolean, wasCancelled: Boolean, isDownloaded: Boolean): Boolean =
        !hasRow && (wasCancelled || isDownloaded)

    /**
     * Server-side problems and transport flakiness are worth a retry from the other host;
     * conditions local to the device, or a cancel, would fail identically.
     */
    fun shouldTryNextSource(error: Throwable): Boolean = when (error) {
        is CancellationException -> false
        is DownloadException -> shouldTryNextSource(error.error)
        else -> true
    }

    fun shouldTryNextSource(error: DownloadError): Boolean = when (error) {
        DownloadError.NotFound, is DownloadError.ServerError, DownloadError.NotAudio, DownloadError.Stalled -> true
        DownloadError.WifiOnly, DownloadError.Offline, DownloadError.DiskFull, DownloadError.SaveFailed -> false
    }

    /** Linux errno for "No space left on device"; Robolectric's OsConstants may not carry real values. */
    private const val ENOSPC = 28

    /** True if any error in the cause chain means the disk is full. */
    fun isOutOfSpace(error: Throwable): Boolean {
        var current: Throwable? = error
        val seen = mutableSetOf<Throwable>()
        while (current != null && seen.add(current)) {
            if (current is ErrnoException && current.errno == ENOSPC) return true
            val message = current.message.orEmpty()
            if ("ENOSPC" in message || "No space left on device" in message) return true
            current = current.cause
        }
        return false
    }

    /** Maps a file error to a short message so the UI never shows a raw exception. */
    fun saveError(error: Throwable): DownloadError = if (isOutOfSpace(error)) DownloadError.DiskFull else DownloadError.SaveFailed

    /** The message a source failure ends with when no other server is left. */
    fun finalError(error: Throwable): DownloadError = when (error) {
        is DownloadException -> error.error
        else -> if (isOutOfSpace(error)) DownloadError.DiskFull else DownloadError.Offline
    }

    fun waitingReason(network: DownloadNetwork, allowCellular: Boolean): WaitingReason? = when (network) {
        DownloadNetwork.OFFLINE -> WaitingReason.CONNECTION
        DownloadNetwork.CELLULAR_ONLY -> if (allowCellular) null else WaitingReason.WIFI
        DownloadNetwork.UNRESTRICTED -> null
    }
}
