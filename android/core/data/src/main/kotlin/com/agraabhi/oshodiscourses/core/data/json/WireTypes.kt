package com.agraabhi.oshodiscourses.core.data.json

import com.agraabhi.oshodiscourses.core.domain.bookmarks.Bookmark
import com.agraabhi.oshodiscourses.core.domain.bookmarks.BookmarkCategory
import com.agraabhi.oshodiscourses.core.domain.sync.CloudSnapshot
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptAlignment
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptAnchor
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptDiscourseState
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptReadPosition
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptSyncedState
import kotlinx.serialization.Serializable

// Wire shapes of the iOS Codable types. Field names and date encoding must stay identical to
// the Swift structs so files and snapshots written by either app decode in the other.

@Serializable
internal data class BookmarkJson(
    val id: String,
    val discourseID: String,
    val seriesName: String,
    val title: String,
    val timestamp: Double,
    val note: String = "",
    val category: BookmarkCategory = BookmarkCategory.RELISTEN,
    val customCategory: String? = null,
    @Serializable(with = AppleDateSerializer::class) val createdAt: Long,
) {
    fun toDomain() = Bookmark(id, discourseID, seriesName, title, timestamp, note, category, customCategory, createdAt)

    companion object {
        fun from(b: Bookmark) = BookmarkJson(b.id, b.discourseID, b.seriesName, b.title, b.timestamp, b.note, b.category, b.customCategory, b.createdAt)
    }
}

@Serializable
internal data class AnchorJson(
    val paragraph: Int,
    val time: Double,
    @Serializable(with = AppleDateSerializer::class) val createdAt: Long,
    val fraction: Double? = null,
) {
    fun toDomain() = TranscriptAnchor(paragraph, time, createdAt, fraction)

    companion object {
        fun from(a: TranscriptAnchor) = AnchorJson(a.paragraph, a.time, a.createdAt, a.fraction)
    }
}

@Serializable
internal data class ReadPositionJson(
    val paragraph: Int,
    @Serializable(with = AppleDateSerializer::class) val updatedAt: Long,
) {
    fun toDomain() = TranscriptReadPosition(paragraph, updatedAt)

    companion object {
        fun from(r: TranscriptReadPosition) = ReadPositionJson(r.paragraph, r.updatedAt)
    }
}

@Serializable
internal data class AlignmentJson(
    val starts: List<Double?>,
    @Serializable(with = AppleDateSerializer::class) val createdAt: Long,
    val engine: String,
) {
    fun toDomain() = TranscriptAlignment(starts, createdAt, engine)

    companion object {
        fun from(a: TranscriptAlignment) = AlignmentJson(a.starts, a.createdAt, a.engine)
    }
}

@Serializable
internal data class DiscourseStateJson(
    val anchors: List<AnchorJson> = emptyList(),
    val readPosition: ReadPositionJson? = null,
    val alignment: AlignmentJson? = null,
    val paragraphCount: Int? = null,
) {
    fun toDomain() = TranscriptDiscourseState(anchors.map { it.toDomain() }, readPosition?.toDomain(), alignment?.toDomain(), paragraphCount)

    companion object {
        fun from(s: TranscriptDiscourseState) = DiscourseStateJson(
            s.anchors.map(AnchorJson::from),
            s.readPosition?.let(ReadPositionJson::from),
            s.alignment?.let(AlignmentJson::from),
            s.paragraphCount,
        )
    }
}

@Serializable
internal data class SyncedStateJson(
    val anchors: List<AnchorJson> = emptyList(),
    val readPosition: ReadPositionJson? = null,
    val paragraphCount: Int? = null,
) {
    fun toDomain() = TranscriptSyncedState(anchors.map { it.toDomain() }, readPosition?.toDomain(), paragraphCount)

    companion object {
        fun from(s: TranscriptSyncedState) = SyncedStateJson(s.anchors.map(AnchorJson::from), s.readPosition?.let(ReadPositionJson::from), s.paragraphCount)
    }
}

@Serializable
internal data class CloudSnapshotJson(
    val positions: Map<String, Double> = emptyMap(),
    val durations: Map<String, Double> = emptyMap(),
    val recentlyPlayed: List<String> = emptyList(),
    val completed: List<String> = emptyList(),
    val listenedCompleted: List<String> = emptyList(),
    val played: List<String>? = null,
    val bookmarks: List<BookmarkJson> = emptyList(),
    val deletedBookmarkIDs: List<String>? = null,
    val dailyStats: Map<String, Double> = emptyMap(),
    val downloaded: List<String> = emptyList(),
    val transcripts: Map<String, SyncedStateJson>? = null,
) {
    fun toDomain() = CloudSnapshot(
        positions = positions,
        durations = durations,
        recentlyPlayed = recentlyPlayed,
        completed = completed,
        listenedCompleted = listenedCompleted,
        played = played,
        bookmarks = bookmarks.map { it.toDomain() },
        deletedBookmarkIDs = deletedBookmarkIDs,
        dailyStats = dailyStats,
        downloaded = downloaded,
        transcripts = transcripts?.mapValues { it.value.toDomain() },
    )

    companion object {
        fun from(s: CloudSnapshot) = CloudSnapshotJson(
            positions = s.positions,
            durations = s.durations,
            recentlyPlayed = s.recentlyPlayed,
            completed = s.completed,
            listenedCompleted = s.listenedCompleted,
            played = s.played,
            bookmarks = s.bookmarks.map(BookmarkJson::from),
            deletedBookmarkIDs = s.deletedBookmarkIDs,
            dailyStats = s.dailyStats,
            downloaded = s.downloaded,
            transcripts = s.transcripts?.mapValues { SyncedStateJson.from(it.value) },
        )
    }
}

/**
 * `playback_state.json`. iOS keeps these in UserDefaults; field names reuse its keys and
 * prefixes, and save times stay epoch seconds as iOS stores them.
 */
@Serializable
internal data class PlaybackStateJson(
    val playbackPosition: Map<String, Double> = emptyMap(),
    val playbackDuration: Map<String, Double> = emptyMap(),
    val playbackSavedAt: Map<String, Double> = emptyMap(),
    val recentlyPlayed: List<String> = emptyList(),
    val completedDiscourseIDs: List<String> = emptyList(),
    val listenedCompletedIDs: List<String> = emptyList(),
    val allPlayedDiscourseIDs: List<String> = emptyList(),
)
