@file:OptIn(ExperimentalCoroutinesApi::class)

package com.agraabhi.oshodiscourses.core.data.json

import com.agraabhi.oshodiscourses.core.data.bookmarks.FileBookmarkRepository
import com.agraabhi.oshodiscourses.core.data.stats.FileListeningStatsRepository
import com.agraabhi.oshodiscourses.core.data.transcript.FileTranscriptStateRepository
import com.agraabhi.oshodiscourses.core.domain.bookmarks.Bookmark
import com.agraabhi.oshodiscourses.core.domain.bookmarks.BookmarkCategory
import com.agraabhi.oshodiscourses.core.domain.stats.DailyListening
import com.agraabhi.oshodiscourses.core.domain.sync.CloudSnapshot
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptAlignment
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptAnchor
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptDiscourseState
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptReadPosition
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptSyncedState
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * Samples in the shape Swift's default `JSONEncoder` writes: Dates as seconds since
 * 2001-01-01, nil optionals omitted, whole numbers without a fraction and `/` escaped.
 */
class IosFormatTest {
    @get:Rule val folder = TemporaryFolder()

    private fun TestScope.io() = UnconfinedTestDispatcher(testScheduler)

    private val iosBookmarks = """
        [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","discourseID":"The_Mustard_Seed-1","seriesName":"The Mustard Seed",
          "title":"The Mustard Seed #1","timestamp":754.5,"note":"Kingdom of God","category":"Profound","createdAt":782000000.25},
         {"createdAt":781999000,"category":"Custom","customCategory":"Laughter","note":"","timestamp":12,"title":"T",
          "seriesName":"S","discourseID":"x-2","id":"A1B2C3D4-0000-0000-0000-000000000000"}]
    """.trimIndent()

    private val iosTranscriptState = """
        {"The_Mustard_Seed-3":{"anchors":[{"paragraph":4,"time":312.5,"createdAt":782000000.25,"fraction":0.25},
          {"paragraph":9,"time":700,"createdAt":782000100}],"readPosition":{"paragraph":-1,"updatedAt":782000200.5},
          "alignment":{"starts":[0,null,20.5],"createdAt":781990000,"engine":"SpeechTranscriber\/en-US"},"paragraphCount":120},
         "x-1":{"anchors":[],"readPosition":{"paragraph":7,"updatedAt":782000000}}}
    """.trimIndent()

    private val iosSnapshot = """
        {"positions":{"d-1":120.5},"durations":{"d-1":600},"recentlyPlayed":["d-1"],"completed":["c-1","c-2"],
         "listenedCompleted":["c-1"],"played":["d-1","c-1","c-2"],
         "bookmarks":[{"id":"B-1","discourseID":"d-1","seriesName":"S","title":"T","timestamp":30,"note":"","category":"Re-listen","createdAt":782000000}],
         "deletedBookmarkIDs":["B-0"],"dailyStats":{"2026-10-16":1800},"downloaded":["d-1"],
         "transcripts":{"d-1":{"anchors":[{"paragraph":2,"time":40,"createdAt":782000000}],"readPosition":{"paragraph":-1,"updatedAt":782000001},"paragraphCount":30}}}
    """.trimIndent()

    @Test fun appleDatesAreSecondsSince2001() {
        assertThat(AppleDateSerializer.fromAppleSeconds(0.0)).isEqualTo(978_307_200_000L)
        assertThat(AppleDateSerializer.fromAppleSeconds(782_000_000.25)).isEqualTo(1_760_307_200_250L)
        assertThat(AppleDateSerializer.toAppleSeconds(1_760_307_200_250L)).isEqualTo(782_000_000.25)
    }

    @Test fun readsAnIosBookmarksFile() = runTest {
        File(folder.root, "bookmarks.json").writeText(iosBookmarks)
        val repo = FileBookmarkRepository(folder.root, io())
        assertThat(repo.bookmarks.value).containsExactly(
            Bookmark("6F9619FF-8B86-D011-B42D-00C04FC964FF", "The_Mustard_Seed-1", "The Mustard Seed", "The Mustard Seed #1", 754.5, "Kingdom of God", BookmarkCategory.PROFOUND, null, 1_760_307_200_250L),
            Bookmark("A1B2C3D4-0000-0000-0000-000000000000", "x-2", "S", "T", 12.0, "", BookmarkCategory.CUSTOM, "Laughter", 1_760_306_200_000L),
        ).inOrder()
    }

    @Test fun writesBookmarksWithTheIosKeys() = runTest {
        val repo = FileBookmarkRepository(folder.root, io(), { 1_760_307_200_250L }, { "ID-1" })
        repo.add("d-1", "S", "T", 5.0)
        val written = Json.parseToJsonElement(File(folder.root, "bookmarks.json").readText()).jsonArray.single().jsonObject
        assertThat(written.keys).containsExactly("id", "discourseID", "seriesName", "title", "timestamp", "note", "category", "createdAt")
        assertThat(written["category"]!!.jsonPrimitive.content).isEqualTo("Re-listen")
        assertThat(written["createdAt"]!!.jsonPrimitive.double).isEqualTo(782_000_000.25)
        assertThat(FileBookmarkRepository(folder.root, io()).bookmarks.value).isEqualTo(repo.bookmarks.value)
    }

    @Test fun readsAnIosListeningStatsFile() = runTest {
        File(folder.root, "listening_stats.json").writeText("""[{"date":"2026-10-16","seconds":1834.5},{"date":"2026-10-17","seconds":60}]""")
        val repo = FileListeningStatsRepository(folder.root, io())
        assertThat(repo.syncedDailyStats()).containsExactly("2026-10-16", 1834.5, "2026-10-17", 60.0)
        assertThat(repo.stats.value.dailyHistory).containsExactly(DailyListening("2026-10-16", 1834.5), DailyListening("2026-10-17", 60.0)).inOrder()
    }

    @Test fun readsAndRewritesAnIosTranscriptStateFile() = runTest {
        File(folder.root, "transcript_state.json").writeText(iosTranscriptState)
        val repo = FileTranscriptStateRepository(folder.root, backgroundScope, io())
        assertThat(repo.state("The_Mustard_Seed-3")).isEqualTo(
            TranscriptDiscourseState(
                anchors = listOf(TranscriptAnchor(4, 312.5, 1_760_307_200_250L, 0.25), TranscriptAnchor(9, 700.0, 1_760_307_300_000L)),
                readPosition = TranscriptReadPosition.following(1_760_307_400_500L),
                alignment = TranscriptAlignment(listOf(0.0, null, 20.5), 1_760_297_200_000L, "SpeechTranscriber/en-US"),
                paragraphCount = 120,
            ),
        )
        assertThat(repo.state("x-1")).isEqualTo(TranscriptDiscourseState(readPosition = TranscriptReadPosition(7, 1_760_307_200_000L)))

        repo.clearAlignment("The_Mustard_Seed-3")
        val written = Json.parseToJsonElement(File(folder.root, "transcript_state.json").readText()).jsonObject
        val discourse = written["The_Mustard_Seed-3"]!!.jsonObject
        assertThat(discourse.keys).containsExactly("anchors", "readPosition", "paragraphCount")
        assertThat(discourse["anchors"]!!.jsonArray[1].jsonObject.keys).containsExactly("paragraph", "time", "createdAt")
        assertThat(written["x-1"]!!.jsonObject.keys).containsExactly("anchors", "readPosition")
    }

    @Test fun decodesAnIosSnapshot() {
        val snapshot = CloudSnapshotCodec.decode(iosSnapshot.encodeToByteArray())
        assertThat(snapshot).isEqualTo(
            CloudSnapshot(
                positions = mapOf("d-1" to 120.5),
                durations = mapOf("d-1" to 600.0),
                recentlyPlayed = listOf("d-1"),
                completed = listOf("c-1", "c-2"),
                listenedCompleted = listOf("c-1"),
                played = listOf("d-1", "c-1", "c-2"),
                bookmarks = listOf(Bookmark("B-1", "d-1", "S", "T", 30.0, "", BookmarkCategory.RELISTEN, null, 1_760_307_200_000L)),
                deletedBookmarkIDs = listOf("B-0"),
                dailyStats = mapOf("2026-10-16" to 1800.0),
                downloaded = listOf("d-1"),
                transcripts = mapOf(
                    "d-1" to TranscriptSyncedState(
                        listOf(TranscriptAnchor(2, 40.0, 1_760_307_200_000L)),
                        TranscriptReadPosition.following(1_760_307_201_000L),
                        30,
                    ),
                ),
            ),
        )
    }

    @Test fun decodesASnapshotFromAnOlderIosVersion() {
        val old = """{"positions":{},"durations":{},"recentlyPlayed":["a"],"completed":[],"listenedCompleted":[],"bookmarks":[],"dailyStats":{},"downloaded":[]}"""
        val snapshot = CloudSnapshotCodec.decode(old.encodeToByteArray())
        assertThat(snapshot.played).isNull()
        assertThat(snapshot.deletedBookmarkIDs).isNull()
        assertThat(snapshot.transcripts).isNull()
        assertThat(snapshot.recentlyPlayed).containsExactly("a")
    }

    @Test fun encodesEveryIosKeyAndOmitsNilOptionals() {
        val withAll = CloudSnapshotCodec.decode(iosSnapshot.encodeToByteArray())
        val json = Json.parseToJsonElement(CloudSnapshotCodec.encode(withAll).decodeToString()).jsonObject
        assertThat(json.keys).containsExactly(
            "positions", "durations", "recentlyPlayed", "completed", "listenedCompleted", "played",
            "bookmarks", "deletedBookmarkIDs", "dailyStats", "downloaded", "transcripts",
        )
        assertThat(json["bookmarks"]!!.jsonArray[0].jsonObject["createdAt"]!!.jsonPrimitive.double).isEqualTo(782_000_000.0)
        assertThat(CloudSnapshotCodec.decode(CloudSnapshotCodec.encode(withAll))).isEqualTo(withAll)

        val bare = Json.parseToJsonElement(CloudSnapshotCodec.encode(CloudSnapshot()).decodeToString()) as JsonObject
        assertThat(bare.keys).containsExactly(
            "positions", "durations", "recentlyPlayed", "completed", "listenedCompleted", "bookmarks", "dailyStats", "downloaded",
        )
    }
}
