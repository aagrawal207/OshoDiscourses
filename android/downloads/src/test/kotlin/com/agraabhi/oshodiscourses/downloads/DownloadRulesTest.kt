package com.agraabhi.oshodiscourses.downloads

import android.system.ErrnoException
import org.robolectric.RobolectricTestRunner
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadError
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadNetwork
import com.agraabhi.oshodiscourses.core.domain.downloads.WaitingReason
import com.google.common.truth.Truth.assertThat
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import java.io.IOException
import java.net.SocketTimeoutException
import kotlin.coroutines.cancellation.CancellationException

/** Port of iOS `UnclaimedDownloadTests` and `DownloadServiceRobustnessTests`, plus the network rules. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36])
class DownloadRulesTest {
    // A transfer can finish while no process is waiting for it, e.g. after the process died.

    @Test
    fun fileFinishedWhileAppWasNotRunningIsKept() {
        assertThat(DownloadRules.discardsUnclaimedFile(hasRow = false, wasCancelled = false, isDownloaded = false)).isFalse()
    }

    @Test
    fun cancelledTransferIsDiscarded() {
        assertThat(DownloadRules.discardsUnclaimedFile(hasRow = false, wasCancelled = true, isDownloaded = false)).isTrue()
    }

    @Test
    fun duplicateOfCommittedDownloadIsDiscarded() {
        assertThat(DownloadRules.discardsUnclaimedFile(hasRow = false, wasCancelled = false, isDownloaded = true)).isTrue()
    }

    @Test
    fun adoptedRowAlwaysCommits() {
        assertThat(DownloadRules.discardsUnclaimedFile(hasRow = true, wasCancelled = true, isDownloaded = true)).isFalse()
    }

    @Test
    fun detectsErrnoOutOfSpace() {
        assertThat(DownloadRules.isOutOfSpace(ErrnoException("write", 28))).isTrue()
    }

    @Test
    fun detectsOutOfSpaceNestedUnderIOException() {
        // The platform wraps ENOSPC in an IOException; the detector walks the cause chain.
        val nested = IOException("write failed", IOException("inner", ErrnoException("write", 28)))
        assertThat(DownloadRules.isOutOfSpace(nested)).isTrue()
        assertThat(DownloadRules.isOutOfSpace(IOException("write failed: ENOSPC (No space left on device)"))).isTrue()
    }

    @Test
    fun ignoresUnrelatedErrors() {
        assertThat(DownloadRules.isOutOfSpace(SocketTimeoutException("timeout"))).isFalse()
        // EACCES is not a full disk.
        assertThat(DownloadRules.isOutOfSpace(IOException("denied", ErrnoException("open", 13)))).isFalse()
    }

    @Test
    fun saveErrorMapsOutOfSpaceToDiskFullAndTheRestToSaveFailed() {
        assertThat(DownloadRules.saveError(IOException(ErrnoException("write", 28)))).isEqualTo(DownloadError.DiskFull)
        assertThat(DownloadRules.saveError(IOException("Permission denied"))).isEqualTo(DownloadError.SaveFailed)
    }

    @Test
    fun diskFullHasShortDescription() {
        val description = DownloadError.DiskFull.message
        assertThat(description.lowercase()).contains("storage")
        // Short enough to fit a row subtitle without truncation.
        assertThat(description.length).isLessThan(60)
    }

    @Test
    fun serverSideFailuresTryTheOtherServerAndLocalOnesDoNot() {
        assertThat(DownloadRules.shouldTryNextSource(DownloadException(DownloadError.NotFound))).isTrue()
        assertThat(DownloadRules.shouldTryNextSource(DownloadException(DownloadError.ServerError(502)))).isTrue()
        assertThat(DownloadRules.shouldTryNextSource(DownloadException(DownloadError.NotAudio))).isTrue()
        assertThat(DownloadRules.shouldTryNextSource(DownloadException(DownloadError.Stalled))).isTrue()
        assertThat(DownloadRules.shouldTryNextSource(TransportException(IOException("reset")))).isTrue()
        assertThat(DownloadRules.shouldTryNextSource(DownloadException(DownloadError.DiskFull))).isFalse()
        assertThat(DownloadRules.shouldTryNextSource(DownloadException(DownloadError.SaveFailed))).isFalse()
        assertThat(DownloadRules.shouldTryNextSource(DownloadException(DownloadError.Offline))).isFalse()
        assertThat(DownloadRules.shouldTryNextSource(DownloadException(DownloadError.WifiOnly))).isFalse()
        assertThat(DownloadRules.shouldTryNextSource(CancellationException())).isFalse()
    }

    @Test
    fun aTransportFailureOnTheLastServerReadsAsOffline() {
        assertThat(DownloadRules.finalError(TransportException(IOException("reset")))).isEqualTo(DownloadError.Offline)
        assertThat(DownloadRules.finalError(DownloadException(DownloadError.NotAudio))).isEqualTo(DownloadError.NotAudio)
    }

    @Test
    fun stalledTransferPastThresholdRestarts() {
        val now = 10_000_000L
        assertThat(DownloadRules.shouldRestartStalledTransfer(now - DownloadRules.STALL_THRESHOLD_MILLIS - 1, now, restartsSoFar = 0)).isTrue()
    }

    @Test
    fun activeTransferWithinThresholdDoesNotRestart() {
        val now = 10_000_000L
        assertThat(DownloadRules.shouldRestartStalledTransfer(now - 30_000, now, restartsSoFar = 0)).isFalse()
    }

    @Test
    fun restartBudgetIsBounded() {
        val now = 10_000_000L
        val last = now - 3_600_000
        assertThat(DownloadRules.shouldRestartStalledTransfer(last, now, restartsSoFar = DownloadRules.MAX_STALL_RESTARTS - 1)).isTrue()
        assertThat(DownloadRules.shouldRestartStalledTransfer(last, now, restartsSoFar = DownloadRules.MAX_STALL_RESTARTS)).isFalse()
    }

    @Test
    fun stallThresholdIsAtExactBoundary() {
        val now = 10_000_000L
        assertThat(DownloadRules.shouldRestartStalledTransfer(now - 120_000, now, restartsSoFar = 0)).isTrue()
        assertThat(DownloadRules.shouldRestartStalledTransfer(now - 119_000, now, restartsSoFar = 0)).isFalse()
    }

    @Test
    fun mobileDataWaitsForWiFiOnlyWhileCellularIsOff() {
        assertThat(DownloadRules.waitingReason(DownloadNetwork.CELLULAR_ONLY, allowCellular = false)).isEqualTo(WaitingReason.WIFI)
        assertThat(DownloadRules.waitingReason(DownloadNetwork.CELLULAR_ONLY, allowCellular = true)).isNull()
        assertThat(DownloadRules.waitingReason(DownloadNetwork.OFFLINE, allowCellular = true)).isEqualTo(WaitingReason.CONNECTION)
        assertThat(DownloadRules.waitingReason(DownloadNetwork.UNRESTRICTED, allowCellular = false)).isNull()
    }

    @Test
    fun errorMessagesMatchIos() {
        assertThat(DownloadError.NotAudio.message).isEqualTo("Server returned a web page, not audio.")
        assertThat(DownloadError.NotFound.message).isEqualTo("Not available on the server (404).")
        assertThat(DownloadError.ServerError(503).message).isEqualTo("Server error (HTTP 503).")
        assertThat(DownloadError.Offline.message).isEqualTo("No internet connection.")
    }

    @Test
    fun markupIsRecognisedEvenWithoutAContentType() {
        val html = "\uFEFF  <!DOCTYPE html><html>".toByteArray()
        assertThat(HttpTransfer.looksLikeMarkup(html, html.size)).isTrue()
        val mp3 = byteArrayOf('I'.code.toByte(), 'D'.code.toByte(), '3'.code.toByte(), 4, 0)
        assertThat(HttpTransfer.looksLikeMarkup(mp3, mp3.size)).isFalse()
        val frame = byteArrayOf(0xFF.toByte(), 0xFB.toByte(), 0x90.toByte())
        assertThat(HttpTransfer.looksLikeMarkup(frame, frame.size)).isFalse()
    }

    @Test
    fun contentRangeParsesKnownAndUnknownTotals() {
        assertThat(ContentRange.parse("bytes 100-199/200")).isEqualTo(ContentRange(100, 199, 200))
        assertThat(ContentRange.parse("bytes 5-9/*")).isEqualTo(ContentRange(5, 9, null))
        assertThat(ContentRange.parse("items 1-2/3")).isNull()
        assertThat(ContentRange.parse(null)).isNull()
    }

    @Test
    fun libraryLayoutMatchesIos() {
        assertThat(DownloadStore.relativePath("A Bird on the Wing", 1)).isEqualTo("Osho Discourses/A Bird on the Wing/A Bird on the Wing - #1.mp3")
        assertThat(DownloadStore.relativePath("Either/Or", 12)).isEqualTo("Osho Discourses/Either-Or/Either-Or - #12.mp3")
    }
}
