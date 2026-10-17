@file:OptIn(ExperimentalCoroutinesApi::class)

package com.agraabhi.oshodiscourses.core.data.sync

import com.agraabhi.oshodiscourses.core.data.bookmarks.FileBookmarkRepository
import com.agraabhi.oshodiscourses.core.data.progress.FilePlaybackStateRepository
import com.agraabhi.oshodiscourses.core.data.stats.FileListeningStatsRepository
import com.agraabhi.oshodiscourses.core.data.transcript.FileTranscriptStateRepository
import com.agraabhi.oshodiscourses.core.domain.bookmarks.Bookmark
import com.agraabhi.oshodiscourses.core.domain.sync.CloudSnapshot
import com.agraabhi.oshodiscourses.core.testing.FakeClock
import com.agraabhi.oshodiscourses.core.testing.FakeDownloadManager
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.time.ZoneOffset

/** Two devices exchanging snapshots, plus the snapshot round trips from `CloudSyncTests` and `SyncMergeTests`. */
class CloudSnapshotCoordinatorTest {
    @get:Rule val folder = TemporaryFolder()

    private val clock = FakeClock(1_792_238_400_000L)
    private var ids = 0

    private inner class Device(name: String, scope: TestScope) {
        private val dir = folder.newFolder(name)
        private val io = UnconfinedTestDispatcher(scope.testScheduler)
        val playback = FilePlaybackStateRepository(dir, io, { clock.nowMillis })
        val bookmarks = FileBookmarkRepository(dir, io, { clock.nowMillis }, { "$name-${ids++}" })
        val stats = FileListeningStatsRepository(dir, io, { clock.nowMillis }, { ZoneOffset.UTC })
        val transcripts = FileTranscriptStateRepository(dir, scope.backgroundScope, io, { clock.nowMillis })
        val downloads = FakeDownloadManager()
        val sync = CloudSnapshotCoordinator(playback, bookmarks, stats, transcripts, downloads)
    }

    /** Order-insensitive view of an export, since `completed` comes from a set. */
    private fun CloudSnapshot.canonical() = copy(completed = completed.sorted(), downloaded = downloaded.sorted())

    @Test fun exportGathersEveryRepository() = runTest {
        val d = Device("a", this)
        d.playback.recordPlay("d-1")
        d.playback.savePosition("d-1", 42.0, 300.0)
        val b = d.bookmarks.add("d-1", "S", "T", 42.0)
        d.bookmarks.remove(d.bookmarks.add("d-1", "S", "gone", 1.0).id)
        d.stats.recordListeningTime(90.0)
        d.downloads.mergeSyncedDownloadHistory(listOf("d-1"))
        d.transcripts.addAnchor("d-1", 3, 50.0, paragraphCount = 20)

        val snapshot = d.sync.export()
        assertThat(snapshot.positions).containsExactly("d-1", 42.0)
        assertThat(snapshot.bookmarks).containsExactly(b)
        assertThat(snapshot.deletedBookmarkIDs).containsExactly("a-1")
        assertThat(snapshot.dailyStats).containsExactly("2026-10-17", 90.0)
        assertThat(snapshot.downloaded).containsExactly("d-1")
        assertThat(snapshot.transcripts?.get("d-1")?.anchors?.single()?.paragraph).isEqualTo(3)
    }

    @Test fun mergingOwnExportChangesNothing() = runTest {
        val d = Device("a", this)
        d.playback.recordPlay("d-1")
        d.playback.savePosition("d-1", 90.0, 300.0)
        d.playback.markCompleted("c-1")
        d.bookmarks.add("d-1", "S", "T", 5.0)
        d.stats.recordListeningTime(600.0)
        d.transcripts.setReadPosition("d-1", 4, paragraphCount = 10)
        val result = d.sync.mergeBytes(d.sync.exportBytes())
        assertThat(result.anyChanged).isFalse()
    }

    @Test fun twoDevicesConvergeAndThenStayPut() = runTest {
        val a = Device("a", this)
        val b = Device("b", this)
        a.playback.recordPlay("x"); a.playback.savePosition("x", 50.0, 500.0); a.playback.markCompleted("done-a")
        a.bookmarks.add("x", "S", "from a", 10.0)
        a.stats.mergeSyncedStats(mapOf("2026-10-16" to 300.0))
        a.transcripts.addAnchor("x", 2, 100.0, paragraphCount = 40)
        a.downloads.mergeSyncedDownloadHistory(listOf("x"))

        clock.advance(5_000)
        b.playback.recordPlay("y"); b.playback.savePosition("x", 80.0, 500.0); b.playback.markListenedComplete("done-b")
        val doomed = b.bookmarks.add("y", "S", "from b", 20.0)
        b.stats.mergeSyncedStats(mapOf("2026-10-16" to 120.0, "2026-10-15" to 60.0))
        b.transcripts.addAnchor("x", 5, 80.0, paragraphCount = 40)
        b.downloads.mergeSyncedDownloadHistory(listOf("y"))

        // Each push overwrites the one Drive file; each pull merges it.
        repeat(2) {
            a.sync.mergeBytes(b.sync.exportBytes())
            b.sync.mergeBytes(a.sync.exportBytes())
        }
        assertThat(a.sync.export().canonical()).isEqualTo(b.sync.export().canonical())
        assertThat(a.sync.merge(b.sync.export()).anyChanged).isFalse()
        assertThat(b.sync.merge(a.sync.export()).anyChanged).isFalse()

        assertThat(a.playback.getPosition("x")).isEqualTo(80.0)
        assertThat(a.bookmarks.bookmarks.value.map(Bookmark::title)).containsExactly("from b", "from a").inOrder()
        assertThat(a.stats.syncedDailyStats()).containsExactly("2026-10-16", 300.0, "2026-10-15", 60.0)
        // b's anchor is newer and pins a later paragraph earlier, so it evicts a's.
        assertThat(a.transcripts.state("x")?.anchors?.map { it.paragraph }).containsExactly(5)
        assertThat(a.downloads.downloadHistory.value).containsExactly("x", "y")

        // A delete on b sticks on a.
        b.bookmarks.remove(doomed.id)
        a.sync.mergeBytes(b.sync.exportBytes())
        assertThat(a.bookmarks.bookmarks.value.map(Bookmark::title)).containsExactly("from a")
        b.sync.mergeBytes(a.sync.exportBytes())
        assertThat(b.bookmarks.bookmarks.value.map(Bookmark::title)).containsExactly("from a")
    }

    @Test fun localChangesFireOnLocalEditsOnly() = runTest {
        val a = Device("a", this)
        var pushes = 0
        backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) { a.sync.localChanges.collect { pushes++ } }
        a.playback.recordPlay("x")
        a.bookmarks.add("x", "S", "T", 1.0)
        a.transcripts.addAnchor("x", 1, 1.0, paragraphCount = 5)
        assertThat(pushes).isEqualTo(3)
        a.sync.merge(CloudSnapshot(completed = listOf("other"), bookmarks = listOf(Bookmark("z", "y", "S", "T", 1.0, createdAt = 1))))
        assertThat(pushes).isEqualTo(3)
    }
}
