package com.agraabhi.oshodiscourses.core.data.bookmarks

import com.agraabhi.oshodiscourses.core.data.AtomicJsonFile
import com.agraabhi.oshodiscourses.core.data.LocalChangeSource
import com.agraabhi.oshodiscourses.core.data.json.BookmarkJson
import com.agraabhi.oshodiscourses.core.domain.bookmarks.Bookmark
import com.agraabhi.oshodiscourses.core.domain.bookmarks.BookmarkCategory
import com.agraabhi.oshodiscourses.core.domain.bookmarks.BookmarkRepository
import com.agraabhi.oshodiscourses.core.domain.bookmarks.BookmarkRepository.Companion.MAX_TOMBSTONES
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import java.io.File
import java.util.UUID

/**
 * [BookmarkRepository] in `bookmarks.json` (the iOS file and format) with tombstones in
 * `deleted_bookmark_ids.json` (iOS keeps them in UserDefaults under `deletedBookmarkIDs`).
 * The constructor reads both files on the calling thread.
 */
class FileBookmarkRepository(
    directory: File,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val clock: () -> Long = System::currentTimeMillis,
    /** iOS mints `UUID().uuidString`, which is upper case. */
    private val newID: () -> String = { UUID.randomUUID().toString().uppercase() },
) : BookmarkRepository, LocalChangeSource {

    private val bookmarksFile = AtomicJsonFile(File(directory, FILE_NAME), ListSerializer(BookmarkJson.serializer()))
    private val tombstonesFile = AtomicJsonFile(File(directory, TOMBSTONES_FILE_NAME), ListSerializer(String.serializer()))
    private val mutex = Mutex()
    private val mutableBookmarks = MutableStateFlow(bookmarksFile.read()?.map { it.toDomain() } ?: emptyList())
    private val mutableTombstones = MutableStateFlow(tombstonesFile.read() ?: emptyList())
    private val changes = MutableSharedFlow<Unit>(extraBufferCapacity = 1, onBufferOverflow = BufferOverflow.DROP_OLDEST)

    override val bookmarks: StateFlow<List<Bookmark>> = mutableBookmarks.asStateFlow()
    override val deletedBookmarkIDs: StateFlow<List<String>> = mutableTombstones.asStateFlow()
    override val localChanges: SharedFlow<Unit> = changes.asSharedFlow()

    override suspend fun add(
        discourseID: String,
        seriesName: String,
        title: String,
        timestamp: Double,
        note: String,
        category: BookmarkCategory,
        customCategory: String?,
    ): Bookmark {
        val bookmark = Bookmark(newID(), discourseID, seriesName, title, timestamp, note, category, customCategory, clock())
        mutex.withLock {
            mutableBookmarks.value = listOf(bookmark) + mutableBookmarks.value
            saveBookmarks()
        }
        changes.tryEmit(Unit)
        return bookmark
    }

    override suspend fun remove(id: String) {
        mutex.withLock {
            mutableBookmarks.value = mutableBookmarks.value.filterNot { it.id == id }
            mutableTombstones.value = ((mutableTombstones.value - id) + id).takeLast(MAX_TOMBSTONES)
            saveTombstones()
            saveBookmarks()
        }
        changes.tryEmit(Unit)
    }

    override suspend fun mergeSynced(incoming: List<Bookmark>, deletedIDs: List<String>): Boolean = mutex.withLock {
        // Tombstones merge first so a delete on either side filters both sets.
        val tombstones = mergeTombstones(mutableTombstones.value, deletedIDs, MAX_TOMBSTONES)
        if (tombstones != mutableTombstones.value) {
            mutableTombstones.value = tombstones
            saveTombstones()
        }
        val merged = mergeBookmarks(mutableBookmarks.value, incoming, tombstones.toSet())
        if (merged == mutableBookmarks.value) return@withLock false
        mutableBookmarks.value = merged
        saveBookmarks()
        true
    }

    private suspend fun saveBookmarks() = withContext(ioDispatcher) {
        bookmarksFile.writeQuietly(mutableBookmarks.value.map(BookmarkJson::from))
    }

    private suspend fun saveTombstones() = withContext(ioDispatcher) { tombstonesFile.writeQuietly(mutableTombstones.value) }

    companion object {
        const val FILE_NAME: String = "bookmarks.json"
        const val TOMBSTONES_FILE_NAME: String = "deleted_bookmark_ids.json"

        /**
         * Union by id minus [deleted], newest first. Local wins a collision; ids are UUIDs minted
         * once, so both copies are the same bookmark. Equal times fall back to id order.
         */
        fun mergeBookmarks(local: List<Bookmark>, incoming: List<Bookmark>, deleted: Set<String> = emptySet()): List<Bookmark> {
            val byID = LinkedHashMap<String, Bookmark>()
            for (b in incoming) if (b.id !in deleted) byID[b.id] = b
            for (b in local) if (b.id !in deleted) byID[b.id] = b
            return byID.values.sortedWith(compareByDescending<Bookmark> { it.createdAt }.thenBy { it.id })
        }

        /** Ordered union; the cap drops the oldest tombstones from the front. */
        fun mergeTombstones(local: List<String>, incoming: List<String>, cap: Int): List<String> =
            LinkedHashSet<String>(local.size + incoming.size).apply { addAll(local); addAll(incoming) }.toList().takeLast(cap)
    }
}
