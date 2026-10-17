package com.agraabhi.oshodiscourses.core.data.transcript

import com.agraabhi.oshodiscourses.core.data.AtomicJsonFile
import com.agraabhi.oshodiscourses.core.data.LocalChangeSource
import com.agraabhi.oshodiscourses.core.data.json.DiscourseStateJson
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptAlignment
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptAnchor
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptDiscourseState
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptReadPosition
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptStateRepository
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptStateRepository.Companion.ANCHORS_PER_DISCOURSE_LIMIT
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptStateRepository.Companion.SYNCED_DISCOURSE_LIMIT
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptSyncedState
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.job
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import java.io.File

private typealias States = Map<String, TranscriptDiscourseState>

/**
 * [TranscriptStateRepository] in `transcript_state.json`, the iOS file and format. Read
 * positions save after a 1 s pause because they change while the reader scrolls; everything
 * else saves before returning. File writes run one at a time under [writeLock].
 */
class FileTranscriptStateRepository(
    directory: File,
    private val scope: CoroutineScope,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val clock: () -> Long = System::currentTimeMillis,
) : TranscriptStateRepository, LocalChangeSource {

    private val file = AtomicJsonFile(File(directory, FILE_NAME), MapSerializer(String.serializer(), DiscourseStateJson.serializer()))

    // Updated only through atomic `update`, because `state(id, count)` mutates without the lock.
    private val mutable = MutableStateFlow<States>(file.read()?.mapValues { it.value.toDomain() } ?: emptyMap())
    private val writeLock = Mutex()
    private val pendingLock = Any()
    private var pendingSave: Job? = null
    private var pendingNotify = false
    private val changes = MutableSharedFlow<Unit>(extraBufferCapacity = 1, onBufferOverflow = BufferOverflow.DROP_OLDEST)

    override val states: StateFlow<States> = mutable.asStateFlow()
    override val localChanges: SharedFlow<Unit> = changes.asSharedFlow()

    override fun state(discourseID: String, paragraphCount: Int): TranscriptDiscourseState {
        var result = TranscriptDiscourseState()
        var changed = false
        mutable.update { m ->
            val stored = m[discourseID] ?: TranscriptDiscourseState()
            result = reconciled(stored, paragraphCount)
            changed = result != stored
            if (changed) m + (discourseID to result) else m
        }
        if (changed) scheduleSave(notify = false)
        return result
    }

    override suspend fun addAnchor(discourseID: String, paragraph: Int, time: Double, fraction: Double?, paragraphCount: Int) {
        val anchor = TranscriptAnchor(paragraph, time, clock(), fraction)
        saveNow(notify = true) { m ->
            val s = reconciled(m[discourseID] ?: TranscriptDiscourseState(), paragraphCount)
            m + (discourseID to s.copy(anchors = cap(TranscriptAnchorRules.inserting(anchor, s.anchors)), paragraphCount = paragraphCount))
        }
    }

    override suspend fun clearAnchors(discourseID: String) {
        saveNow(notify = true) { m ->
            val s = m[discourseID]
            if (s == null || s.anchors.isEmpty()) m else m + (discourseID to s.copy(anchors = emptyList()))
        }
    }

    override suspend fun setReadPosition(discourseID: String, paragraph: Int, paragraphCount: Int) {
        val now = clock()
        var moved = false
        var changed = false
        mutable.update { m ->
            val stored = m[discourseID] ?: TranscriptDiscourseState()
            val s = reconciled(stored, paragraphCount)
            moved = s.readPosition?.paragraph != paragraph
            val next = if (moved) s.copy(readPosition = TranscriptReadPosition(paragraph, now), paragraphCount = paragraphCount) else s
            changed = next != stored
            if (changed) m + (discourseID to next) else m
        }
        if (changed) scheduleSave(notify = moved)
    }

    override suspend fun clearReadPosition(discourseID: String) {
        val now = clock()
        var changed = false
        mutable.update { m ->
            val s = m[discourseID]
            val read = s?.readPosition
            changed = s != null && read != null && !read.isFollowing
            if (changed) m + (discourseID to s!!.copy(readPosition = TranscriptReadPosition.following(now))) else m
        }
        if (changed) scheduleSave(notify = true)
    }

    override suspend fun setAlignment(discourseID: String, alignment: TranscriptAlignment, paragraphCount: Int) {
        saveNow(notify = false) { m ->
            val s = reconciled(m[discourseID] ?: TranscriptDiscourseState(), paragraphCount)
            m + (discourseID to s.copy(alignment = alignment, paragraphCount = paragraphCount))
        }
    }

    override suspend fun clearAlignment(discourseID: String) {
        saveNow(notify = false) { m ->
            val s = m[discourseID]
            if (s?.alignment == null) m else m + (discourseID to s.copy(alignment = null))
        }
    }

    override fun syncedStates(): Map<String, TranscriptSyncedState> = mutable.value.entries
        .filter { it.value.anchors.isNotEmpty() || it.value.readPosition != null }
        .sortedWith(compareByDescending<Map.Entry<String, TranscriptDiscourseState>> { it.value.lastActivity }.thenBy { it.key })
        .take(SYNCED_DISCOURSE_LIMIT)
        .associate { (id, s) -> id to s.synced() }

    override suspend fun mergeSynced(incoming: Map<String, TranscriptSyncedState>): Boolean =
        saveNow(notify = false) { m -> applyMerge(m, incoming) }

    /** Writes a pending read-position save now, e.g. when the app goes to the background. */
    suspend fun flush() {
        saveNow(notify = false) { it }
    }

    /**
     * Applies [transform] and, if it changed anything, writes the file before returning. A
     * pending debounced save is folded in, keeping its notification.
     */
    private suspend fun saveNow(notify: Boolean, transform: (States) -> States): Boolean {
        var notifyNow = false
        val changed = writeLock.withLock {
            var changed = false
            mutable.update { m -> transform(m).also { changed = it != m } }
            val carried = takePending(expected = null)
            if (changed || carried != null) write()
            notifyNow = (changed && notify) || carried == true
            changed
        }
        if (notifyNow) changes.tryEmit(Unit)
        return changed
    }

    private fun scheduleSave(notify: Boolean) {
        // Holding the lock while launching means the job cannot look for itself before it is recorded.
        synchronized(pendingLock) {
            pendingSave?.cancel()
            pendingNotify = pendingNotify || notify
            pendingSave = scope.launch {
                delay(SAVE_DEBOUNCE_MILLIS)
                var notifyNow = false
                writeLock.withLock {
                    val taken = takePending(expected = coroutineContext.job) ?: return@withLock
                    write()
                    notifyNow = taken
                }
                if (notifyNow) changes.tryEmit(Unit)
            }
        }
    }

    /**
     * Clears the pending save and returns its notify flag, or null when there is none or a
     * newer save replaced [expected]. A null [expected] takes whatever is pending.
     */
    private fun takePending(expected: Job?): Boolean? = synchronized(pendingLock) {
        val pending = pendingSave ?: return null
        if (expected != null && pending !== expected) return null
        if (expected == null) pending.cancel()
        pendingSave = null
        pendingNotify.also { pendingNotify = false }
    }

    private suspend fun write() {
        val snapshot = mutable.value.filterValues { !it.isEmpty }.mapValues { DiscourseStateJson.from(it.value) }
        withContext(ioDispatcher) { file.writeQuietly(snapshot) }
    }

    companion object {
        const val FILE_NAME: String = "transcript_state.json"
        const val SAVE_DEBOUNCE_MILLIS: Long = 1_000

        /** A different paragraph count means a re-split transcript; its anchors and alignment no longer apply. */
        internal fun reconciled(s: TranscriptDiscourseState, paragraphCount: Int): TranscriptDiscourseState {
            val stored = s.paragraphCount ?: return s
            if (stored == paragraphCount) return s
            val read = s.readPosition
            return s.copy(
                anchors = emptyList(),
                alignment = null,
                paragraphCount = paragraphCount,
                readPosition = if (read != null && !read.isFollowing && read.paragraph >= paragraphCount) null else read,
            )
        }

        internal fun applyMerge(m: States, incoming: Map<String, TranscriptSyncedState>): States {
            var out = m
            for ((id, remote) in incoming) {
                val local = out[id]
                val localSynced = local?.synced()
                val merged = merge(localSynced, remote)
                if (merged == localSynced) continue
                var s = (local ?: TranscriptDiscourseState()).copy(anchors = merged.anchors, readPosition = merged.readPosition)
                if (s.paragraphCount != merged.paragraphCount) {
                    // The other device's split won; this device's alignment refers to the old one.
                    s = s.copy(alignment = null, paragraphCount = merged.paragraphCount)
                }
                out = out + (id to s)
            }
            return out
        }

        /**
         * Order-independent merge of one discourse (iOS `TranscriptStateService.merge`). Anchors
         * union and the newer read position wins when both sides share a paragraph split;
         * otherwise the side with more recent activity is taken whole.
         */
        fun merge(local: TranscriptSyncedState?, incoming: TranscriptSyncedState): TranscriptSyncedState {
            if (local == null) return normalized(incoming)
            val a = local.paragraphCount
            val b = incoming.paragraphCount
            if (a != null && b != null && a != b) {
                if (local.lastActivity == incoming.lastActivity) return normalized(if (a > b) local else incoming)
                return normalized(if (local.lastActivity > incoming.lastActivity) local else incoming)
            }
            val l = local.readPosition
            val r = incoming.readPosition
            val read = when {
                l != null && r != null -> when {
                    l.updatedAt != r.updatedAt -> if (r.updatedAt > l.updatedAt) r else l
                    // Equal times break by paragraph so both devices pick the same one.
                    else -> if (r.paragraph > l.paragraph) r else l
                }
                else -> l ?: r
            }
            return TranscriptSyncedState(
                anchors = cap(TranscriptAnchorRules.merge(local.anchors, incoming.anchors)),
                readPosition = read,
                paragraphCount = a ?: b,
            )
        }

        private fun normalized(s: TranscriptSyncedState) = s.copy(anchors = cap(TranscriptAnchorRules.merge(s.anchors, emptyList())))

        /** Keeps the newest anchors when a discourse collects too many. */
        internal fun cap(anchors: List<TranscriptAnchor>): List<TranscriptAnchor> {
            if (anchors.size <= ANCHORS_PER_DISCOURSE_LIMIT) return anchors
            return anchors.sortedByDescending { it.createdAt }.take(ANCHORS_PER_DISCOURSE_LIMIT).sortedBy { it.paragraph }
        }

        private fun TranscriptDiscourseState.synced() = TranscriptSyncedState(anchors, readPosition, paragraphCount)
    }
}
