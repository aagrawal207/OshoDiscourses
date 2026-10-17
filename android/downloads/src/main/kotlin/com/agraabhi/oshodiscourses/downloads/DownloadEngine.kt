package com.agraabhi.oshodiscourses.downloads

import android.net.Uri
import android.util.Log
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadError
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadManager
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadNetwork
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadSource
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadState
import com.agraabhi.oshodiscourses.core.domain.downloads.WaitingReason
import com.agraabhi.oshodiscourses.core.domain.settings.SettingsRepository
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptRepository
import com.agraabhi.oshodiscourses.core.model.CatalogDiscourse
import com.agraabhi.oshodiscourses.core.model.CatalogRepository
import com.agraabhi.oshodiscourses.core.model.URLEncoding
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import java.io.File
import java.io.IOException
import kotlin.coroutines.cancellation.CancellationException

/**
 * iOS `DownloadService`: a persisted one-at-a-time queue, run by a host ([TransferScheduler]) that
 * calls [runQueue]. After process death the queue and partial files are recovered and resumed.
 */
class DownloadEngine(
    private val store: DownloadStore,
    private val catalog: CatalogRepository,
    private val settings: SettingsRepository,
    private val transcripts: TranscriptRepository,
    private val networkMonitor: NetworkMonitor,
    private val scheduler: TransferScheduler,
    private val speedStore: SourceSpeedStore,
    private val httpClient: OkHttpClient,
    private val transfer: HttpTransfer,
    private val isNearOshoworld: () -> Boolean,
    private val scope: CoroutineScope,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    /** Enables [applyDebugNetworkArgument]; only debuggable builds pass true. */
    private val debugFeaturesEnabled: Boolean = false,
    private val fileUri: (File) -> String = { Uri.fromFile(it).toString() },
) : DownloadManager {

    /** The running or next transfer, for the host's progress notification. */
    data class ActiveTransfer(val discourseID: String, val title: String, val state: DownloadState, val queuedBehind: Int)

    private val lock = Any()
    private val pathMap = LinkedHashMap<String, String>()
    private val sizes = HashMap<String, Long>()
    private val history = LinkedHashSet<String>()

    /** Request order; the head occupies the single transfer slot. */
    private val queue = ArrayList<String>()
    private val failures = LinkedHashMap<String, DownloadError>()

    /** Ids the listener cancelled or deleted in this process; a late finished file for one is discarded. */
    private val cancelledIDs = HashSet<String>()
    private var headProgress: DownloadState.Downloading? = null
    private var current: Pair<String, Job>? = null
    private var sourceSpeeds: Map<DownloadSource, Double> = speedStore.load()
    private var appliedAllowCellular: Boolean = settings.settings.value.allowCellularDownloads

    private val ready = CompletableDeferred<Unit>()
    private val runnerMutex = Mutex()
    private val debugNetwork = MutableStateFlow<DownloadNetwork?>(null)
    private val queueFlow = MutableStateFlow<List<String>>(emptyList())

    private val mutableStates = MutableStateFlow<Map<String, DownloadState>>(emptyMap())
    private val mutableDownloaded = MutableStateFlow<Set<String>>(emptySet())
    private val mutableHistory = MutableStateFlow<Set<String>>(emptySet())
    private val mutableNetwork = MutableStateFlow(networkMonitor.network.value)
    private val mutableWaiting = MutableStateFlow<WaitingReason?>(null)
    private val mutableStorage = MutableStateFlow(0L)
    private val mutableActive = MutableStateFlow<ActiveTransfer?>(null)

    override val states: StateFlow<Map<String, DownloadState>> = mutableStates.asStateFlow()
    override val downloadedIDs: StateFlow<Set<String>> = mutableDownloaded.asStateFlow()
    override val downloadHistory: StateFlow<Set<String>> = mutableHistory.asStateFlow()
    override val network: StateFlow<DownloadNetwork> = mutableNetwork.asStateFlow()
    override val waitingReason: StateFlow<WaitingReason?> = mutableWaiting.asStateFlow()
    override val storageUsedBytes: StateFlow<Long> = mutableStorage.asStateFlow()
    val activeTransfer: StateFlow<ActiveTransfer?> = mutableActive.asStateFlow()

    /** Bytes the queued transfers will need, for the job's payload estimate. */
    val estimatedQueueBytes: Long get() = synchronized(lock) { queue.size } * ESTIMATED_BYTES_PER_DISCOURSE

    init {
        synchronized(lock) {
            pathMap.putAll(store.loadManifest())
            history.addAll(store.loadHistory())
            queue.addAll(store.loadQueue().distinct())
            publishLocked()
        }
        scope.launch(ioDispatcher) {
            try {
                recover()
            } finally {
                ready.complete(Unit)
            }
            scheduleIfNeeded()
        }
        scope.launch {
            combine(networkMonitor.network, debugNetwork, settings.settings.map { it.allowCellularDownloads }) { _, _, _ -> }
                .collect { publish() }
        }
        scope.launch {
            settings.settings.map { it.allowCellularDownloads }.distinctUntilChanged().drop(1).collect { applyCellularSetting(it) }
        }
        scope.launch {
            usableUpdates().drop(1).collect { usable -> if (usable) scheduleIfNeeded() }
        }
    }

    /** Waits for the launch recovery pass; tests and hosts call this before inspecting state. */
    suspend fun awaitReady() = ready.await()

    // region DownloadManager

    override fun localFileURI(discourseID: String): String? {
        val relative = synchronized(lock) { pathMap[discourseID] } ?: return null
        val file = store.file(relative)
        if (file.exists()) return fileUri(file)
        // File missing on disk: evict from the manifest, as iOS does lazily.
        scope.launch(ioDispatcher) { evictMissing(listOf(discourseID)) }
        return null
    }

    override suspend fun enqueue(discourseID: String) = enqueueAll(listOf(discourseID))

    override suspend fun enqueueAll(discourseIDs: List<String>) {
        ready.await()
        val added = withContext(ioDispatcher) {
            synchronized(lock) {
                var added = false
                for (id in discourseIDs) {
                    if (id in queue) continue
                    val relative = pathMap[id]
                    if (relative != null && store.file(relative).exists()) continue
                    if (catalog.entry(id) == null) {
                        Log.w(TAG, "enqueue skipped: not in catalog")
                        continue
                    }
                    failures.remove(id)
                    cancelledIDs.remove(id)
                    queue.add(id)
                    added = true
                }
                if (added) {
                    store.saveQueue(queue)
                    publishLocked()
                }
                added
            }
        }
        if (added) scheduleIfNeeded()
    }

    override suspend fun cancel(discourseID: String) {
        ready.await()
        val running = synchronized(lock) {
            cancelledIDs.add(discourseID)
            failures.remove(discourseID)
            val wasHead = queue.firstOrNull() == discourseID
            val removed = queue.remove(discourseID)
            if (wasHead) headProgress = null
            if (removed) store.saveQueue(queue)
            publishLocked()
            current?.takeIf { it.first == discourseID }?.second
        }
        running?.cancelAndJoin()
        withContext(ioDispatcher) { store.partial(discourseID).delete() }
        Log.i(TAG, "cancelled")
        // A running host ends by itself once the queue drains; a waiting one would start for nothing.
        if (synchronized(lock) { queue.isEmpty() } && !runnerMutex.isLocked) scheduler.cancelPending()
    }

    override suspend fun delete(discourseID: String) = deleteDownloads(listOf(discourseID))

    override suspend fun deleteDownloads(discourseIDs: List<String>) {
        ready.await()
        val active = synchronized(lock) { discourseIDs.filter { it in queue || it in failures } }
        active.forEach { cancel(it) }
        val removed = withContext(ioDispatcher) {
            val removed = synchronized(lock) {
                val removed = discourseIDs.mapNotNull { id -> pathMap.remove(id)?.let { id to it } }
                discourseIDs.forEach {
                    sizes.remove(it)
                    // A late finish from a superseded transfer must not bring the file back.
                    cancelledIDs.add(it)
                }
                if (removed.isNotEmpty()) store.saveManifest(pathMap)
                publishLocked()
                removed
            }
            for ((_, relative) in removed) {
                val file = store.file(relative)
                file.delete()
                val parent = file.parentFile
                if (parent != null && parent != store.audioRoot && parent.list()?.isEmpty() == true) parent.delete()
            }
            removed
        }
        if (removed.isNotEmpty()) Log.i(TAG, "deleted count=${removed.size}")
        for ((id, _) in removed) {
            runCatching { transcripts.remove(id) }.onFailure { if (it is CancellationException) throw it }
        }
    }

    override suspend fun deleteSeries(seriesID: String) {
        val downloaded = downloadedIDs.value
        val fromCatalog = catalog.series(seriesID)?.let { series -> catalog.discourses(series).map { it.id } }.orEmpty()
        val byPrefix = downloaded.filter { it.startsWith("$seriesID-") && it.removePrefix("$seriesID-").toIntOrNull() != null }
        deleteDownloads((fromCatalog.filter { it in downloaded } + byPrefix).distinct())
    }

    override suspend fun deleteAll() = deleteDownloads(downloadedIDs.value.toList())

    override suspend fun useMobileData() {
        settings.setAllowCellularDownloads(true)
        applyCellularSetting(true)
    }

    override suspend fun downloadedSizes(): Map<String, Long> {
        ready.await()
        return synchronized(lock) { HashMap(sizes) }
    }

    override fun inProgressIDs(): List<String> = synchronized(lock) { queue.toList() }

    override suspend fun mergeSyncedDownloadHistory(incoming: List<String>): Boolean = withContext(ioDispatcher) {
        synchronized(lock) {
            val before = history.size
            history.addAll(incoming)
            if (history.size == before) return@withContext false
            store.saveHistory(history)
            publishLocked()
            true
        }
    }

    override suspend fun forgetDownloadHistory(discourseIDs: List<String>) = withContext(ioDispatcher) {
        synchronized(lock) {
            // Anything on disk stays: it would be re-seeded on the next launch anyway.
            val removable = discourseIDs.filter { it !in pathMap }
            if (history.removeAll(removable.toSet())) {
                store.saveHistory(history)
                publishLocked()
            }
        }
    }

    override fun syncedDownloadHistory(): List<String> = synchronized(lock) { history.toList() }

    // endregion

    /**
     * Call when the app comes to the foreground. A user-initiated job can only be scheduled while
     * the app is visible, so this is when a queue left by a stopped host gets one again.
     */
    fun resumePendingTransfers() {
        scope.launch(ioDispatcher) {
            ready.await()
            scheduleIfNeeded()
        }
    }

    /**
     * Debug builds only: `cellularOnly` or `offline` fakes the network (iOS `-debugDownloadNetwork`)
     * and holds transfers, since a faked network cannot stop a real one.
     */
    fun applyDebugNetworkArgument(value: String?) {
        if (!debugFeaturesEnabled) return
        debugNetwork.value = when (value) {
            "cellularOnly" -> DownloadNetwork.CELLULAR_ONLY
            "offline" -> DownloadNetwork.OFFLINE
            else -> null
        }
        Log.i(TAG, "debug network=${debugNetwork.value}")
    }

    /**
     * Runs the queue front to back until empty; a second host waits for the first. Cancellation (the
     * host was stopped) keeps the queue and partial file. Returns true when the queue drained.
     */
    suspend fun runQueue(): Boolean {
        ready.await()
        return runnerMutex.withLock {
            Log.i(TAG, "runner started")
            while (true) {
                // Wait until there is something to do and the network allows it.
                val head = combine(queueFlow, usableUpdates()) { q, usable -> q.firstOrNull() to usable }
                    .first { (head, usable) -> head == null || usable }
                    .first ?: break
                if (debugNetwork.value != null) {
                    queueFlow.first { it.firstOrNull() != head }
                    continue
                }
                coroutineScope {
                    val job = launch(ioDispatcher) {
                        try {
                            transferHead(head)
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: Exception) {
                            Log.e(TAG, "transfer crashed", e)
                            fail(head, DownloadRules.saveError(e))
                        }
                    }
                    synchronized(lock) { current = head to job }
                    job.join()
                    synchronized(lock) { if (current?.first == head) current = null }
                }
            }
            Log.i(TAG, "runner idle")
            true
        }
    }

    private suspend fun transferHead(id: String) {
        val entry = catalog.entry(id)
        if (entry == null) {
            removeFromQueue(id)
            return
        }
        val discourse = entry.discourse
        val relative = store.relativePath(discourse)
        val destination = store.file(relative)
        // The file may already be there (seeded, or committed by an earlier process); don't re-download it.
        if (destination.exists() && destination.length() > 0) {
            withContext(ioDispatcher) { recordCommitted(id, relative, destination.length()) }
            return
        }
        val sources = sources(discourse)
        if (sources.isEmpty()) {
            fail(id, DownloadError.NotFound)
            return
        }
        val partial = store.partial(id)
        for ((index, pair) in sources.withIndex()) {
            val (source, url) = pair
            val hasFallback = index < sources.lastIndex
            try {
                val result = transfer.fetch(
                    client = httpClient,
                    discourseID = id,
                    url = url,
                    partial = partial,
                    maxRestarts = DownloadRules.maxRestarts(hasFallback),
                    isUsable = ::isUsableNow,
                    usableUpdates = usableUpdates(),
                    onProgress = { bytes, total -> updateProgress(id, bytes, total) },
                )
                if (result.activeMillis > 0 && result.bytesReceived > 0) {
                    recordSpeed(source, result.bytesReceived * 1000.0 / result.activeMillis)
                }
                Log.i(TAG, "source=${source.rawValue} position=$index outcome=completed")
                withContext(ioDispatcher) { commit(id, discourse, partial) }
                return
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (e is DownloadException && e.error == DownloadError.Stalled) recordSpeed(source, 0.0)
                val outcome = (e as? DownloadException)?.error?.let { it.javaClass.simpleName } ?: "transport"
                Log.w(TAG, "source=${source.rawValue} position=$index outcome=$outcome")
                withContext(ioDispatcher) { partial.delete() }
                if (!hasFallback || !DownloadRules.shouldTryNextSource(e)) {
                    fail(id, DownloadRules.finalError(e))
                    return
                }
                synchronized(lock) {
                    if (queue.firstOrNull() == id) headProgress = DownloadState.Downloading(0.0, 0, null)
                    publishLocked()
                }
            }
        }
    }

    /** Nearer server first (see [DownloadSourcePolicy]); the other is the fallback, including for unmirrored talks. */
    private fun sources(discourse: CatalogDiscourse): List<Pair<DownloadSource, HttpUrl>> {
        val urls = buildMap {
            catalog.archiveAudioURL(discourse)?.toHttpUrlOrNull()?.let { put(DownloadSource.ARCHIVE, it) }
            // Foundation's query-allowed encoding, so the request bytes match iOS; OkHttp's own differs.
            URLEncoding.requestURL(discourse.audioURL)?.toHttpUrlOrNull()?.let { put(DownloadSource.OSHOWORLD, it) }
        }
        val speeds = synchronized(lock) { sourceSpeeds }
        return DownloadSourcePolicy.order(urls.keys, speeds, isNearOshoworld()).mapNotNull { s -> urls[s]?.let { s to it } }
    }

    private fun recordSpeed(source: DownloadSource, bytesPerSecond: Double) {
        val speeds = synchronized(lock) {
            sourceSpeeds = sourceSpeeds + (source to DownloadSourcePolicy.blended(sourceSpeeds[source], bytesPerSecond))
            sourceSpeeds
        }
        speedStore.save(speeds)
    }

    /** Moves a finished partial into the library, unless the listener cancelled it meanwhile. */
    private fun commit(id: String, discourse: CatalogDiscourse, partial: PartialFile) {
        val relative = store.relativePath(discourse)
        val destination = store.file(relative)
        val discard = synchronized(lock) {
            DownloadRules.discardsUnclaimedFile(hasRow = id in queue, wasCancelled = id in cancelledIDs, isDownloaded = id in pathMap)
        }
        if (discard) {
            partial.delete()
            return
        }
        try {
            val parent = destination.parentFile ?: throw IOException("no parent")
            if (!parent.isDirectory && !parent.mkdirs()) throw IOException("cannot create ${parent.name}")
            if (destination.exists()) destination.delete()
            if (!partial.dataFile.renameTo(destination)) {
                partial.dataFile.copyTo(destination, overwrite = true)
                partial.dataFile.delete()
            }
            partial.metaFile.delete()
        } catch (e: IOException) {
            destination.delete()
            partial.delete()
            fail(id, DownloadRules.saveError(e))
            return
        }
        recordCommitted(id, relative, destination.length())
        scope.launch {
            runCatching { transcripts.prefetch(id, allowCellular()) }.onFailure { Log.w(TAG, "transcript prefetch failed", it) }
        }
    }

    private fun recordCommitted(id: String, relative: String, size: Long) {
        synchronized(lock) {
            pathMap[id] = relative
            sizes[id] = size
            if (history.add(id)) store.saveHistory(history)
            store.saveManifest(pathMap)
            failures.remove(id)
            removeFromQueueLocked(id)
            publishLocked()
        }
        Log.i(TAG, "committed")
    }

    private fun fail(id: String, error: DownloadError) {
        synchronized(lock) {
            if (id !in queue) return
            failures[id] = error
            removeFromQueueLocked(id)
            publishLocked()
        }
        Log.w(TAG, "failed error=${error.javaClass.simpleName}")
    }

    private fun removeFromQueue(id: String) = synchronized(lock) {
        removeFromQueueLocked(id)
        publishLocked()
    }

    private fun removeFromQueueLocked(id: String) {
        val wasHead = queue.firstOrNull() == id
        if (queue.remove(id)) store.saveQueue(queue)
        if (wasHead) headProgress = null
    }

    private fun updateProgress(id: String, bytes: Long, total: Long?) {
        synchronized(lock) {
            if (queue.firstOrNull() != id) return
            val fraction = if (total != null && total > 0) (bytes.toDouble() / total).coerceIn(0.0, 1.0) else 0.0
            headProgress = DownloadState.Downloading(fraction, bytes, total)
            publishLocked()
        }
    }

    // region Recovery

    /**
     * Drops manifest entries whose file is gone, adopts files the manifest lost (a crash between move
     * and save), and commits or discards partial files left by a dead process.
     */
    private fun recover() {
        val known = synchronized(lock) { pathMap.toMap() }
        val present = HashMap<String, String>()
        val sizesFound = HashMap<String, Long>()
        for ((id, relative) in known) {
            val file = store.file(relative)
            if (file.isFile) {
                present[id] = relative
                sizesFound[id] = file.length()
            }
        }
        val claimedPaths = present.values.toHashSet()
        val orphans = store.audioRoot.listFiles().orEmpty()
            .filter { it.isDirectory }
            .flatMap { dir -> dir.listFiles().orEmpty().filter { it.isFile && it.name.endsWith(".mp3") } }
            .map { "${DownloadStore.ROOT_FOLDER}/${it.parentFile!!.name}/${it.name}" to it }
            .filter { (relative, _) -> relative !in claimedPaths }
        if (orphans.isNotEmpty()) {
            val byPath = catalog.allDiscourses().associateBy({ store.relativePath(it) }, { it.id })
            for ((relative, file) in orphans) {
                val id = byPath[relative] ?: continue
                present[id] = relative
                sizesFound[id] = file.length()
            }
        }

        synchronized(lock) {
            val manifestChanged = present != pathMap
            pathMap.clear()
            pathMap.putAll(present)
            sizes.clear()
            sizes.putAll(sizesFound)
            if (manifestChanged) store.saveManifest(pathMap)
            // Anything on disk is by definition part of the history.
            if (history.addAll(pathMap.keys)) store.saveHistory(history)
            val queueBefore = queue.toList()
            queue.removeAll { it in pathMap || catalog.entry(it) == null }
            if (queue != queueBefore) store.saveQueue(queue)
            publishLocked()
        }

        for (partial in store.allPartials()) {
            val meta = partial.readMeta()
            val id = meta?.discourseID
            val entry = id?.let { catalog.entry(it) }
            if (id == null || entry == null) {
                partial.delete()
                continue
            }
            val (hasRow, isDownloaded) = synchronized(lock) { (id in queue) to (id in pathMap) }
            if (partial.isComplete) {
                if (DownloadRules.discardsUnclaimedFile(hasRow, wasCancelled = false, isDownloaded = isDownloaded)) {
                    partial.delete()
                } else {
                    // Finished while no process was waiting; claim it.
                    synchronized(lock) { if (id !in queue) queue.add(0, id) }
                    commit(id, entry.discourse, partial)
                }
            } else if (!hasRow) {
                partial.delete()
            } else {
                synchronized(lock) {
                    if (queue.firstOrNull() == id) {
                        val total = meta.totalBytes
                        val fraction = if (total != null && total > 0) partial.size.toDouble() / total else 0.0
                        headProgress = DownloadState.Downloading(fraction.coerceIn(0.0, 1.0), partial.size, total)
                        publishLocked()
                    }
                }
            }
        }
        Log.i(TAG, "recovered downloaded=${pathMap.size} queued=${queue.size}")
    }

    private fun evictMissing(ids: List<String>) {
        synchronized(lock) {
            val missing = ids.filter { id -> pathMap[id]?.let { !store.file(it).exists() } == true }
            if (missing.isEmpty()) return
            missing.forEach {
                pathMap.remove(it)
                sizes.remove(it)
            }
            store.saveManifest(pathMap)
            publishLocked()
        }
    }

    // endregion

    // region Network and scheduling

    private fun currentNetwork(): DownloadNetwork = debugNetwork.value ?: networkMonitor.network.value

    private fun allowCellular(): Boolean = settings.settings.value.allowCellularDownloads

    private fun isUsableNow(): Boolean = DownloadRules.waitingReason(currentNetwork(), allowCellular()) == null

    private fun usableUpdates(): Flow<Boolean> =
        combine(networkMonitor.network, debugNetwork, settings.settings.map { it.allowCellularDownloads }) { real, debug, allow ->
            DownloadRules.waitingReason(debug ?: real, allow) == null
        }.distinctUntilChanged()

    /** Hosts carry the cellular rule in their network constraint, so a change replaces the host; Range resume keeps the bytes. */
    private suspend fun applyCellularSetting(allowed: Boolean) {
        val changed = synchronized(lock) {
            val changed = appliedAllowCellular != allowed
            appliedAllowCellular = allowed
            publishLocked()
            changed
        }
        if (!changed) return
        Log.i(TAG, "allowCellular=$allowed")
        ready.await()
        if (synchronized(lock) { queue.isNotEmpty() }) scheduler.schedule(allowed, estimatedQueueBytes, replace = true)
    }

    private fun scheduleIfNeeded() {
        if (synchronized(lock) { queue.isEmpty() }) return
        scheduler.schedule(allowCellular(), estimatedQueueBytes, replace = false)
    }

    // endregion

    private fun publish() = synchronized(lock) { publishLocked() }

    private fun publishLocked() {
        val network = currentNetwork()
        val reason = if (queue.isNotEmpty()) DownloadRules.waitingReason(network, allowCellular()) else null
        val map = HashMap<String, DownloadState>(pathMap.size + queue.size + failures.size)
        for (id in pathMap.keys) map[id] = DownloadState.Downloaded
        for ((id, error) in failures) map[id] = DownloadState.Failed(error)
        var headState: DownloadState? = null
        queue.forEachIndexed { index, id ->
            val state = if (index > 0) {
                DownloadState.Queued
            } else {
                when (reason) {
                    WaitingReason.WIFI -> DownloadState.WaitingForWifi
                    WaitingReason.CONNECTION -> DownloadState.WaitingForConnection
                    null -> headProgress ?: DownloadState.Downloading(0.0, 0, null)
                }
            }
            if (index == 0) headState = state
            map[id] = state
        }
        mutableStates.value = map
        mutableDownloaded.value = pathMap.keys.toSet()
        mutableHistory.value = history.toSet()
        mutableStorage.value = sizes.values.sum()
        mutableNetwork.value = network
        mutableWaiting.value = reason
        queueFlow.value = queue.toList()
        mutableActive.value = queue.firstOrNull()?.let { id ->
            ActiveTransfer(id, catalog.entry(id)?.discourse?.displayTitle ?: id, headState!!, queue.size - 1)
        }
    }

    companion object {
        /** Discourses run about 20-30 MB; long ones more. Generous so the system does not cut a long queue short. */
        const val ESTIMATED_BYTES_PER_DISCOURSE: Long = 40L * 1024 * 1024
    }
}

private const val TAG = "Downloads"
