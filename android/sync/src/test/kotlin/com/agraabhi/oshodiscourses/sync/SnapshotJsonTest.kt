package com.agraabhi.oshodiscourses.sync

import com.agraabhi.oshodiscourses.core.domain.sync.CloudSnapshot
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptSyncedState
import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** Ports `CloudSyncTests.snapshotCodableRoundTrip`, plus the compatibility the Drive file needs. */
class SnapshotJsonTest {
    @Test
    fun roundTripKeepsEveryField() {
        val snapshot = CloudSnapshot(
            positions = mapOf("a" to 1.5),
            durations = mapOf("a" to 60.0),
            recentlyPlayed = listOf("a", "b"),
            completed = listOf("c"),
            listenedCompleted = listOf("d"),
            played = listOf("a", "c"),
            bookmarks = listOf(bookmark("b-1")),
            deletedBookmarkIDs = listOf("b-0"),
            dailyStats = mapOf("2026-10-17" to 600.0),
            downloaded = listOf("a"),
            transcripts = mapOf("a" to TranscriptSyncedState(paragraphCount = 12)),
        )

        assertEquals(snapshot, SnapshotJson.decode(SnapshotJson.encode(snapshot)))
    }

    @Test
    fun olderSnapshotWithoutOptionalFieldsDecodes() {
        val decoded = SnapshotJson.decode("""{"positions":{"a":3.0},"completed":["c"]}""")!!

        assertEquals(mapOf("a" to 3.0), decoded.positions)
        assertNull(decoded.played)
        assertNull(decoded.deletedBookmarkIDs)
        assertNull(decoded.transcripts)
    }

    @Test
    fun newerSnapshotWithUnknownFieldsDecodes() {
        val decoded = SnapshotJson.decode("""{"completed":["c"],"favourites":["x"]}""")
        assertEquals(listOf("c"), decoded?.completed)
    }

    @Test
    fun garbageIsNotASnapshot() {
        assertNull(SnapshotJson.decode("not json"))
        assertNull(SnapshotJson.decode("""{"completed":42}"""))
    }
}
