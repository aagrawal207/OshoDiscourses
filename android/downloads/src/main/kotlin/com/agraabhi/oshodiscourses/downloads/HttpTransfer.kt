package com.agraabhi.oshodiscourses.downloads

import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadError
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InterruptedIOException
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.cancellation.CancellationException

/** The network went away mid-transfer; the attempt pauses instead of counting as a failure. */
internal class NetworkLostException : IOException("network unavailable")

/** The server's range answer did not line up with the partial file; start again from byte 0. */
private class RestartFromZeroException : IOException("range mismatch")

/**
 * One source's transfer into a [PartialFile], resumed by HTTP Range. As on iOS, a watchdog restarts a
 * transfer frozen for [stallThresholdMillis], then gives up with Stalled; a lost network only pauses.
 */
class HttpTransfer(
    private val stallThresholdMillis: Long = DownloadRules.STALL_THRESHOLD_MILLIS,
    /** Bytes this app may still write next to the given directory. */
    private val freeSpace: (File) -> Long,
    private val clock: () -> Long = System::currentTimeMillis,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    data class Result(val bytesReceived: Long, val activeMillis: Long, val totalBytes: Long)

    private enum class Interrupt { NONE, NETWORK_LOST, RESTART, ABANDON }

    suspend fun fetch(
        client: OkHttpClient,
        discourseID: String,
        url: HttpUrl,
        partial: PartialFile,
        maxRestarts: Int,
        isUsable: () -> Boolean,
        usableUpdates: Flow<Boolean>,
        onProgress: (bytesOnDisk: Long, totalBytes: Long?) -> Unit,
    ): Result {
        var restarts = 0
        var received = 0L
        var activeMillis = 0L
        var restartedFromZero = false
        while (true) {
            if (!isUsable()) usableUpdates.first { it }
            val started = clock()
            val lastProgress = AtomicLong(started)
            val attemptBytes = AtomicLong(0)
            val interrupt = AtomicReference(Interrupt.NONE)
            try {
                val total = coroutineScope {
                    val call = client.newCall(request(url, partial))
                    val watcher = launch {
                        try {
                            usableUpdates.first { !it }
                            interrupt.set(Interrupt.NETWORK_LOST)
                        } finally {
                            call.cancel()
                        }
                    }
                    val watchdog = launch {
                        while (true) {
                            delay((stallThresholdMillis / 4).coerceAtLeast(10))
                            val action = DownloadRules.stallAction(lastProgress.get(), clock(), restarts, maxRestarts, stallThresholdMillis)
                            if (action != DownloadRules.StallAction.NONE) {
                                interrupt.set(if (action == DownloadRules.StallAction.RESTART) Interrupt.RESTART else Interrupt.ABANDON)
                                call.cancel()
                                return@launch
                            }
                        }
                    }
                    try {
                        withContext(ioDispatcher) {
                            call.execute().use { response ->
                                receive(response, discourseID, url, partial, lastProgress, attemptBytes, onProgress)
                            }
                        }
                    } finally {
                        watcher.cancel()
                        watchdog.cancel()
                    }
                }
                received += attemptBytes.get()
                activeMillis += clock() - started
                return Result(received, activeMillis, total)
            } catch (e: CancellationException) {
                throw e
            } catch (e: DownloadException) {
                throw e
            } catch (e: IOException) {
                received += attemptBytes.get()
                activeMillis += clock() - started
                currentCoroutineContext().ensureActive()
                when {
                    e is RestartFromZeroException -> {
                        if (restartedFromZero) throw TransportException(e)
                        restartedFromZero = true
                    }
                    interrupt.get() == Interrupt.NETWORK_LOST || e is NetworkLostException || !isUsable() -> Unit
                    interrupt.get() == Interrupt.RESTART -> restarts++
                    interrupt.get() == Interrupt.ABANDON -> throw DownloadException(DownloadError.Stalled, e)
                    // OkHttp's own timeouts are the same symptom the watchdog looks for.
                    e is InterruptedIOException -> if (restarts < maxRestarts) restarts++ else throw DownloadException(DownloadError.Stalled, e)
                    // A dropped connection after bytes flowed resumes; one that never delivers is the server's problem.
                    attemptBytes.get() > 0 && restarts < maxRestarts -> restarts++
                    else -> throw TransportException(e)
                }
            }
        }
    }

    private fun request(url: HttpUrl, partial: PartialFile): Request {
        val builder = Request.Builder().url(url)
            // Transparent gzip would make byte offsets meaningless for Range.
            .header("Accept-Encoding", "identity")
        val meta = partial.readMeta()
        val offset = partial.size
        if (meta != null && meta.url == url.toString() && offset > 0) {
            builder.header("Range", "bytes=$offset-")
            meta.validator?.let { builder.header("If-Range", it) }
        } else if (offset > 0 || meta != null) {
            partial.delete()
        }
        return builder.build()
    }

    /** Returns the total size once every byte is in [partial]. */
    private fun receive(
        response: Response,
        discourseID: String,
        url: HttpUrl,
        partial: PartialFile,
        lastProgress: AtomicLong,
        attemptBytes: AtomicLong,
        onProgress: (Long, Long?) -> Unit,
    ): Long {
        val requestedOffset = partial.size
        val meta = partial.readMeta()
        var offset: Long
        val total: Long?
        when (val code = response.code) {
            206 -> {
                val range = ContentRange.parse(response.header("Content-Range"))
                if (range == null || range.start != requestedOffset) {
                    partial.delete()
                    throw RestartFromZeroException()
                }
                offset = requestedOffset
                total = range.total ?: meta?.totalBytes
            }
            416 -> {
                val known = meta?.totalBytes
                if (known != null && requestedOffset == known) return known
                partial.delete()
                throw RestartFromZeroException()
            }
            404 -> {
                partial.delete()
                throw DownloadException(DownloadError.NotFound)
            }
            in 200..299 -> {
                // The server ignored the range or the file changed: start over.
                if (requestedOffset > 0) partial.dataFile.delete()
                offset = 0
                total = response.body.contentLength().takeIf { it >= 0 }
            }
            else -> {
                partial.delete()
                throw DownloadException(DownloadError.ServerError(code))
            }
        }
        if (response.header("Content-Type").orEmpty().contains("text/html", ignoreCase = true)) {
            partial.delete()
            throw DownloadException(DownloadError.NotAudio)
        }
        if (total != null) {
            val remaining = total - offset
            if (remaining > 0 && freeSpace(partial.dataFile.parentFile ?: partial.dataFile) < remaining) {
                throw DownloadException(DownloadError.DiskFull)
            }
        }
        val validator = if (offset == 0L) validator(response) else meta?.validator
        try {
            partial.writeMeta(PartialMeta(discourseID, url.toString(), validator, total))
        } catch (e: IOException) {
            throw DownloadException(DownloadRules.saveError(e), e)
        }

        onProgress(offset, total)
        var lastReported = offset
        val reportStep = total?.let { (it / 100).coerceAtLeast(1) } ?: UNKNOWN_SIZE_STEP
        val buffer = ByteArray(BUFFER_SIZE)
        var sniffed = offset > 0
        val source = response.body.byteStream()
        val output = try {
            FileOutputStream(partial.dataFile, offset > 0)
        } catch (e: IOException) {
            throw DownloadException(DownloadRules.saveError(e), e)
        }
        output.use { out ->
            while (true) {
                val read = source.read(buffer)
                if (read < 0) break
                if (read == 0) continue
                if (!sniffed) {
                    sniffed = true
                    if (looksLikeMarkup(buffer, read)) {
                        partial.delete()
                        throw DownloadException(DownloadError.NotAudio)
                    }
                }
                try {
                    out.write(buffer, 0, read)
                } catch (e: IOException) {
                    throw DownloadException(DownloadRules.saveError(e), e)
                }
                offset += read
                attemptBytes.addAndGet(read.toLong())
                if (offset - lastReported >= reportStep || offset == total) {
                    lastReported = offset
                    // The watchdog counts whole-percent steps, like iOS progress events.
                    lastProgress.set(clock())
                    onProgress(offset, total)
                }
            }
        }
        if (total != null && offset < total) throw IOException("connection closed at $offset of $total bytes")
        if (offset == 0L) throw IOException("empty response body")
        onProgress(offset, total ?: offset)
        if (total == null) partial.writeMeta(PartialMeta(discourseID, url.toString(), validator, offset))
        return total ?: offset
    }

    private fun validator(response: Response): String? {
        val etag = response.header("ETag")
        // If-Range only accepts a strong validator.
        if (etag != null && !etag.startsWith("W/")) return etag
        return response.header("Last-Modified")
    }

    companion object {
        private const val BUFFER_SIZE = 64 * 1024
        private const val UNKNOWN_SIZE_STEP = 256L * 1024

        /** Captive portals and error pages answer 200 with HTML, sometimes without a content type. */
        internal fun looksLikeMarkup(bytes: ByteArray, length: Int): Boolean {
            var i = 0
            if (length >= 3 && bytes[0] == 0xEF.toByte() && bytes[1] == 0xBB.toByte() && bytes[2] == 0xBF.toByte()) i = 3
            while (i < length && bytes[i].toInt().toChar().isWhitespace()) i++
            return i < length && bytes[i] == '<'.code.toByte()
        }
    }
}

/** `Content-Range: bytes <start>-<end>/<total or *>`. */
internal data class ContentRange(val start: Long, val end: Long, val total: Long?) {
    companion object {
        private val pattern = Regex("""bytes\s+(\d+)-(\d+)/(\d+|\*)""", RegexOption.IGNORE_CASE)

        fun parse(header: String?): ContentRange? {
            val match = header?.let { pattern.find(it) } ?: return null
            val (start, end, total) = match.destructured
            return ContentRange(start.toLong(), end.toLong(), total.toLongOrNull())
        }
    }
}
