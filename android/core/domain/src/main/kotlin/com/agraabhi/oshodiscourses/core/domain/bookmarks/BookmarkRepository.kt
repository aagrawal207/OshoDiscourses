package com.agraabhi.oshodiscourses.core.domain.bookmarks

import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Bookmarks in `bookmarks.json` (iOS `BookmarkService`). Deletes leave tombstones (newest 500)
 * so they stick across devices instead of resurrecting from a stale snapshot.
 */
interface BookmarkRepository {
    /** Newest first by [Bookmark.createdAt]. */
    val bookmarks: StateFlow<List<Bookmark>>

    val deletedBookmarkIDs: StateFlow<List<String>>

    suspend fun add(
        discourseID: String,
        seriesName: String,
        title: String,
        timestamp: Double,
        note: String = "",
        category: BookmarkCategory = BookmarkCategory.RELISTEN,
        customCategory: String? = null,
    ): Bookmark

    suspend fun remove(id: String)

    fun bookmarksFor(discourseID: String): List<Bookmark> = bookmarks.value.filter { it.discourseID == discourseID }

    fun bookmarksIn(category: BookmarkCategory): List<Bookmark> = bookmarks.value.filter { it.category == category }

    /** Union by id minus tombstones from either side. True if the local set changed. */
    suspend fun mergeSynced(incoming: List<Bookmark>, deletedIDs: List<String> = emptyList()): Boolean

    companion object {
        const val MAX_TOMBSTONES: Int = 500
    }
}

/** iOS `BookmarkCategory`; the raw value is both the label and the persisted string. */
@Serializable
enum class BookmarkCategory(val rawValue: String) {
    @SerialName("Re-listen") RELISTEN("Re-listen"),
    @SerialName("Funny") FUNNY("Funny"),
    @SerialName("Awesome") AWESOME("Awesome"),
    @SerialName("Profound") PROFOUND("Profound"),
    @SerialName("Meditation") MEDITATION("Meditation"),
    @SerialName("Custom") CUSTOM("Custom"),
}

/** iOS `Bookmark`: one moment in a discourse. */
@Serializable
data class Bookmark(
    /** UUID minted once at creation. */
    val id: String,
    val discourseID: String,
    val seriesName: String,
    val title: String,
    /** Seconds into the discourse. */
    val timestamp: Double,
    val note: String = "",
    val category: BookmarkCategory = BookmarkCategory.RELISTEN,
    val customCategory: String? = null,
    /** Epoch milliseconds. */
    val createdAt: Long,
) {
    /** "m:ss", or "h:mm:ss" past an hour. */
    val formattedTimestamp: String
        get() {
            val total = timestamp.toInt()
            val hrs = total / 3600
            val mins = (total % 3600) / 60
            val secs = total % 60
            return if (hrs > 0) "%d:%02d:%02d".format(hrs, mins, secs) else "%d:%02d".format(mins, secs)
        }

    val displayCategory: String
        get() = if (category == BookmarkCategory.CUSTOM && !customCategory.isNullOrEmpty()) customCategory else category.rawValue
}
