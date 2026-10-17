package com.agraabhi.oshodiscourses.transcript

import com.agraabhi.oshodiscourses.core.domain.transcript.TimingSource
import com.agraabhi.oshodiscourses.core.domain.transcript.Transcript
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptAvailability
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptDiscourseState
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptException
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptRepository
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptTiming
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import java.io.File

/**
 * Fetches, caches and serves transcripts (iOS `TranscriptService`). Text is fetched behind each
 * committed download so reading works offline, and on demand otherwise. Files live in
 * `noBackupFilesDir/transcripts/`: like the audio they are re-downloadable and only bloat a backup.
 */
class TranscriptService(
    private val directory: File,
    catalog: Lazy<TranscriptCatalog> = lazy(TranscriptCatalog::loadShipped),
    alignments: Lazy<AlignmentCatalog> = lazy(AlignmentCatalog::loadShipped),
    private val fetchHTML: suspend (TranscriptCatalog.Entry, Boolean) -> String,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val parseDispatcher: CoroutineDispatcher = Dispatchers.Default,
    private val clock: () -> Long = System::currentTimeMillis,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + ioDispatcher),
) : TranscriptRepository {
    private val catalog by catalog
    private val alignments by alignments

    private val cached = MutableStateFlow(loadIndex())
    override val cachedIDs: StateFlow<Set<String>> = cached.asStateFlow()

    private val loading = MutableStateFlow<Set<String>>(emptySet())
    override val loadingIDs: StateFlow<Set<String>> = loading.asStateFlow()

    private val lock = Any()
    private val inFlight = HashMap<String, Deferred<Transcript>>()

    // The few transcripts open recently; ~60 KB each, so a handful is plenty.
    private val memory = object : LinkedHashMap<String, Transcript>(MEMORY_LIMIT + 1, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Transcript>?): Boolean = size > MEMORY_LIMIT
    }

    init {
        // availability() and timing() are synchronous UI calls; parse both catalogs off the main thread first.
        scope.launch {
            this@TranscriptService.catalog
            this@TranscriptService.alignments
        }
    }

    override fun availability(discourseID: String): TranscriptAvailability = when {
        discourseID in cached.value -> TranscriptAvailability.CACHED
        catalog.hasTranscript(discourseID) -> TranscriptAvailability.NOT_CACHED
        else -> TranscriptAvailability.UNAVAILABLE
    }

    /** Number of a series' discourses with a transcript, for the series-row indicator. */
    fun transcriptCount(seriesID: String): Int = catalog.transcriptCount(seriesID)

    override suspend fun transcript(discourseID: String, allowsCellular: Boolean): Transcript {
        synchronized(lock) { memory[discourseID] }?.let { return it }
        readFromDisk(discourseID)?.let { onDisk ->
            remember(onDisk)
            return onDisk
        }
        val entry = catalog.entry(discourseID) ?: throw TranscriptException.NoDescription()
        val task = synchronized(lock) {
            inFlight[discourseID] ?: run {
                loading.update { it + discourseID }
                // Runs in the service scope so a reader closed mid-fetch still caches the text.
                scope.async { fetchAndCache(discourseID, entry, allowsCellular) }.also { inFlight[discourseID] = it }
            }
        }
        return task.await()
    }

    private suspend fun fetchAndCache(discourseID: String, entry: TranscriptCatalog.Entry, allowsCellular: Boolean): Transcript {
        try {
            val html = fetchHTML(entry, allowsCellular)
            val paragraphs = withContext(parseDispatcher) { TranscriptParser.paragraphs(html) }
            val transcript = Transcript(discourseID, entry.id, clock(), paragraphs)
            if (transcript.wordCount < TranscriptRepository.MINIMUM_WORDS) throw TranscriptException.Blank()
            writeToDisk(transcript)
            remember(transcript)
            return transcript
        } finally {
            synchronized(lock) { inFlight.remove(discourseID) }
            loading.update { it - discourseID }
        }
    }

    override suspend fun prefetch(discourseID: String, allowsCellular: Boolean) {
        if (availability(discourseID) != TranscriptAvailability.NOT_CACHED) return
        if (synchronized(lock) { discourseID in inFlight }) return
        try {
            transcript(discourseID, allowsCellular)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            // Silent: the reader fetches on demand and shows the error there.
        }
    }

    /**
     * One at a time so it never competes with an audio download. Site answers are per-discourse
     * and skipped; three transport failures in a row mean offline, so it stops.
     */
    override suspend fun backfill(downloadedIDs: List<String>, allowsCellular: Boolean) {
        var failures = 0
        for (id in downloadedIDs.filter { availability(it) == TranscriptAvailability.NOT_CACHED }) {
            try {
                transcript(id, allowsCellular)
                failures = 0
            } catch (e: CancellationException) {
                throw e
            } catch (e: TranscriptException) {
                if (e is TranscriptException.Network && ++failures >= BACKFILL_FAILURE_LIMIT) return
            } catch (_: Exception) {
                if (++failures >= BACKFILL_FAILURE_LIMIT) return
            }
        }
    }

    /** Drops the cached text with the audio. Anchors and read positions are user data and stay. */
    override suspend fun remove(discourseID: String) {
        synchronized(lock) { memory.remove(discourseID) }
        cached.update { it - discourseID }
        withContext(ioDispatcher) { fileFor(discourseID).delete() }
    }

    /**
     * Shipped starts when they fit this split and recording, else device alignment, else the estimate;
     * anchors bend all three. Callers pass state without `alignment` when speech sync is off.
     */
    override fun timing(transcript: Transcript, duration: Double, state: TranscriptDiscourseState): TranscriptTiming {
        val count = transcript.paragraphs.size
        val base = TranscriptSyncModel(transcript.paragraphs, duration)
        val shipped = shippedAlignment(transcript.discourseID, count, duration)
        val device = state.alignment?.starts?.takeIf { it.size == count }
        val (starts, source) = when {
            shipped != null -> shipped.starts to TimingSource.SHIPPED_ALIGNMENT
            device != null -> device to TimingSource.DEVICE_ALIGNMENT
            else -> null to TimingSource.ESTIMATE
        }
        val knots = starts?.let { base.knots(it, state.anchors) } ?: state.anchors.mapNotNull { base.knot(it) }
        return base.with(knots, source)
    }

    /** The shipped entry only when it describes this paragraph split and recording. */
    fun shippedAlignment(discourseID: String, paragraphCount: Int, duration: Double): AlignmentCatalog.Entry? {
        if (duration <= 0) return null
        return alignments.entry(discourseID)?.takeIf { it.matches(paragraphCount, duration) }
    }

    // Ids are "<language>-<filePrefix>-<n>" and path-safe, but a slash would escape the folder.
    private fun fileFor(discourseID: String): File = File(directory, discourseID.replace('/', '-') + ".json")

    private fun loadIndex(): Set<String> =
        directory.listFiles { file -> file.extension == "json" }?.mapTo(HashSet()) { it.nameWithoutExtension }.orEmpty()

    private suspend fun readFromDisk(discourseID: String): Transcript? = withContext(ioDispatcher) {
        val file = fileFor(discourseID)
        val transcript = runCatching { json.decodeFromString<Transcript>(file.readText()) }.getOrNull()
        // Missing or corrupt: forget it so the next open re-fetches.
        if (transcript == null) cached.update { it - discourseID }
        transcript
    }

    private suspend fun writeToDisk(transcript: Transcript) = withContext(ioDispatcher) {
        runCatching {
            directory.mkdirs()
            val target = fileFor(transcript.discourseID)
            val temp = File(directory, target.name + ".tmp")
            temp.writeText(json.encodeToString(Transcript.serializer(), transcript))
            if (!temp.renameTo(target)) {
                temp.delete()
                error("rename failed")
            }
            cached.update { it + transcript.discourseID }
        }
    }

    private fun remember(transcript: Transcript) {
        synchronized(lock) { memory[transcript.discourseID] = transcript }
    }

    companion object {
        const val MEMORY_LIMIT: Int = 4
        const val BACKFILL_FAILURE_LIMIT: Int = 3
        const val DIRECTORY_NAME: String = "transcripts"

        private val json = Json { ignoreUnknownKeys = true }
    }
}
