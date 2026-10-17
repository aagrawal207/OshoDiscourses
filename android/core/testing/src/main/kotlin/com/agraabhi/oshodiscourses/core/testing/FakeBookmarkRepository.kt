package com.agraabhi.oshodiscourses.core.testing

import com.agraabhi.oshodiscourses.core.domain.bookmarks.Bookmark
import com.agraabhi.oshodiscourses.core.domain.bookmarks.BookmarkCategory
import com.agraabhi.oshodiscourses.core.domain.bookmarks.BookmarkRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update

class FakeBookmarkRepository(
    initial: List<Bookmark> = emptyList(),
    private val clock: FakeClock = FakeClock(),
) : BookmarkRepository {
    override val bookmarks = MutableStateFlow(initial.sortedByDescending { it.createdAt })
    override val deletedBookmarkIDs = MutableStateFlow<List<String>>(emptyList())
    private var nextID = 0

    override suspend fun add(
        discourseID: String,
        seriesName: String,
        title: String,
        timestamp: Double,
        note: String,
        category: BookmarkCategory,
        customCategory: String?,
    ): Bookmark {
        val bookmark = Bookmark(
            id = "fake-bookmark-${nextID++}",
            discourseID = discourseID,
            seriesName = seriesName,
            title = title,
            timestamp = timestamp,
            note = note,
            category = category,
            customCategory = customCategory,
            createdAt = clock.nowMillis,
        )
        bookmarks.update { listOf(bookmark) + it }
        return bookmark
    }

    override suspend fun remove(id: String) {
        bookmarks.update { list -> list.filterNot { it.id == id } }
        deletedBookmarkIDs.update { (it - id + id).takeLast(BookmarkRepository.MAX_TOMBSTONES) }
    }

    override suspend fun mergeSynced(incoming: List<Bookmark>, deletedIDs: List<String>): Boolean {
        deletedBookmarkIDs.update { (it + deletedIDs).distinct().takeLast(BookmarkRepository.MAX_TOMBSTONES) }
        val deleted = deletedBookmarkIDs.value.toSet()
        val merged = (incoming + bookmarks.value).associateBy { it.id }.values
            .filterNot { it.id in deleted }
            .sortedByDescending { it.createdAt }
        if (merged == bookmarks.value) return false
        bookmarks.value = merged
        return true
    }
}
