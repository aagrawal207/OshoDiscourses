@file:OptIn(ExperimentalCoroutinesApi::class)

package com.agraabhi.oshodiscourses.core.data.bookmarks

import com.agraabhi.oshodiscourses.core.domain.bookmarks.Bookmark
import com.agraabhi.oshodiscourses.core.domain.bookmarks.BookmarkCategory
import com.agraabhi.oshodiscourses.core.testing.FakeClock
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/** Ports the bookmark half of `SyncMergeTests`, plus the `BookmarkService` persistence rules. */
class FileBookmarkRepositoryTest {
    @get:Rule val folder = TemporaryFolder()

    private val clock = FakeClock(1_700_000_000_000L)
    private var nextID = 0

    private fun TestScope.repo(dir: File = folder.root) =
        FileBookmarkRepository(dir, UnconfinedTestDispatcher(testScheduler), { clock.nowMillis }, { "id-${nextID++}" })

    private fun bookmark(id: String, createdAt: Long, discourse: String = "d1") =
        Bookmark(id = id, discourseID = discourse, seriesName = "S", title = "T", timestamp = 10.0, createdAt = createdAt)

    @Test fun bookmarkMergeUnionsDistinctEntries() {
        val merged = FileBookmarkRepository.mergeBookmarks(listOf(bookmark("a", 1)), listOf(bookmark("b", 2, "d2")))
        assertThat(merged.map { it.id }).containsExactly("b", "a").inOrder()
    }

    @Test fun bookmarkMergeDeduplicatesByID() {
        val shared = bookmark("a", 1)
        assertThat(FileBookmarkRepository.mergeBookmarks(listOf(shared), listOf(shared))).containsExactly(shared)
    }

    @Test fun bookmarkMergeIsIdempotent() {
        val a = bookmark("a", 1)
        val b = bookmark("b", 2)
        val once = FileBookmarkRepository.mergeBookmarks(listOf(a, b), listOf(a))
        val twice = FileBookmarkRepository.mergeBookmarks(once, listOf(a, b))
        assertThat(twice).isEqualTo(once)
        assertThat(twice).hasSize(2)
    }

    @Test fun bookmarkMergeSortsNewestFirst() {
        val older = bookmark("older", 1_000)
        val newer = bookmark("newer", 2_000)
        assertThat(FileBookmarkRepository.mergeBookmarks(listOf(older), listOf(newer))).containsExactly(newer, older).inOrder()
    }

    @Test fun localCopyWinsACollision() {
        val local = bookmark("a", 1).copy(note = "local")
        val incoming = bookmark("a", 1).copy(note = "incoming")
        assertThat(FileBookmarkRepository.mergeBookmarks(listOf(local), listOf(incoming)).single().note).isEqualTo("local")
    }

    @Test fun deletedBookmarkIsFilteredFromMerge() {
        val a = bookmark("a", 1)
        val b = bookmark("b", 2)
        assertThat(FileBookmarkRepository.mergeBookmarks(listOf(b), listOf(a, b), setOf("a")).map { it.id }).containsExactly("b")
    }

    @Test fun tombstoneRemovesLocalCopyToo() {
        assertThat(FileBookmarkRepository.mergeBookmarks(listOf(bookmark("a", 1)), emptyList(), setOf("a"))).isEmpty()
    }

    @Test fun tombstoneMergeIsUnionAndIdempotent() {
        val once = FileBookmarkRepository.mergeTombstones(listOf("x", "y"), listOf("y", "z"), 500)
        assertThat(once).containsExactly("x", "y", "z").inOrder()
        assertThat(FileBookmarkRepository.mergeTombstones(once, listOf("y", "z"), 500)).isEqualTo(once)
    }

    @Test fun tombstoneCapTrimsOldestEntries() {
        assertThat(FileBookmarkRepository.mergeTombstones(listOf("old1", "old2"), listOf("new"), 2)).containsExactly("old2", "new").inOrder()
    }

    @Test fun addPutsNewestFirstAndPersists() = runTest {
        val repo = repo()
        repo.add("d1", "Series", "First", 12.0)
        clock.advance(1_000)
        val second = repo.add("d2", "Series", "Second", 34.0, note = "n", category = BookmarkCategory.CUSTOM, customCategory = "Laughter")
        assertThat(repo.bookmarks.value.map { it.title }).containsExactly("Second", "First").inOrder()
        assertThat(second.createdAt).isEqualTo(1_700_000_001_000L)
        assertThat(second.displayCategory).isEqualTo("Laughter")
        assertThat(repo.bookmarksFor("d1").map { it.title }).containsExactly("First")
        assertThat(repo().bookmarks.value).isEqualTo(repo.bookmarks.value)
    }

    @Test fun removeRecordsATombstoneThatSurvivesRelaunch() = runTest {
        val repo = repo()
        val b = repo.add("d1", "S", "T", 1.0)
        repo.remove(b.id)
        assertThat(repo.bookmarks.value).isEmpty()
        assertThat(repo.deletedBookmarkIDs.value).containsExactly(b.id)
        val reloaded = repo()
        assertThat(reloaded.deletedBookmarkIDs.value).containsExactly(b.id)
        // A stale snapshot from another device still carries it.
        assertThat(reloaded.mergeSynced(listOf(b))).isFalse()
        assertThat(reloaded.bookmarks.value).isEmpty()
    }

    @Test fun mergeSyncedAppliesIncomingTombstonesAndReportsChange() = runTest {
        val repo = repo()
        val mine = repo.add("d1", "S", "Mine", 1.0)
        val theirs = bookmark("theirs", 1_600_000_000_000L)
        assertThat(repo.mergeSynced(listOf(theirs))).isTrue()
        assertThat(repo.bookmarks.value.map { it.id }).containsExactly(mine.id, "theirs").inOrder()
        assertThat(repo.mergeSynced(listOf(theirs))).isFalse()
        assertThat(repo.mergeSynced(emptyList(), deletedIDs = listOf(mine.id))).isTrue()
        assertThat(repo.bookmarks.value.map { it.id }).containsExactly("theirs")
    }

    @Test fun tombstonesKeepTheNewest500() = runTest {
        val repo = repo()
        repo.mergeSynced(emptyList(), (1..600).map { "t$it" })
        assertThat(repo.deletedBookmarkIDs.value).hasSize(500)
        assertThat(repo.deletedBookmarkIDs.value.first()).isEqualTo("t101")
    }

    @Test fun corruptFileIsPreservedAsBackup() = runTest {
        File(folder.root, FileBookmarkRepository.FILE_NAME).writeText("[{\"id\":")
        val repo = repo()
        assertThat(repo.bookmarks.value).isEmpty()
        assertThat(File(folder.root, "bookmarks.json.bak").readText()).isEqualTo("[{\"id\":")
        assertThat(File(folder.root, FileBookmarkRepository.FILE_NAME).exists()).isFalse()
    }
}
