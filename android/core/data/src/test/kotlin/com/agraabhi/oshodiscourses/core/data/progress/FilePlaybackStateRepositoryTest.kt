@file:OptIn(ExperimentalCoroutinesApi::class)

package com.agraabhi.oshodiscourses.core.data.progress

import com.agraabhi.oshodiscourses.core.domain.sync.CloudSnapshot
import com.agraabhi.oshodiscourses.core.testing.FakeClock
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Ports `PlaybackStateTests` and the progress half of `CloudSyncTests`. */
class FilePlaybackStateRepositoryTest {
    @get:Rule val folder = TemporaryFolder()

    private val clock = FakeClock(1_700_000_000_000L)

    private fun TestScope.repo() = FilePlaybackStateRepository(folder.root, UnconfinedTestDispatcher(testScheduler), { clock.nowMillis })

    // PlaybackStateTests

    @Test fun recordPlayAddsToRecent() = runTest {
        val s = repo()
        s.recordPlay("test-1")
        assertThat(s.state.value.recentlyPlayed).contains("test-1")
    }

    @Test fun recordPlayPutsNewestFirst() = runTest {
        val s = repo()
        s.recordPlay("test-1")
        s.recordPlay("test-2")
        assertThat(s.state.value.recentlyPlayed.first()).isEqualTo("test-2")
    }

    @Test fun recordPlayDeduplicates() = runTest {
        val s = repo()
        s.recordPlay("test-1")
        s.recordPlay("test-2")
        s.recordPlay("test-1")
        assertThat(s.state.value.recentlyPlayed).containsExactly("test-1", "test-2").inOrder()
    }

    @Test fun saveAndGetPosition() = runTest {
        val s = repo()
        s.savePosition("test-1", 123.5)
        assertThat(s.getPosition("test-1")).isEqualTo(123.5)
    }

    @Test fun clearPositionRemovesPositionAndRecent() = runTest {
        val s = repo()
        s.recordPlay("test-1")
        s.savePosition("test-1", 60.0, 600.0)
        s.clearPosition("test-1")
        assertThat(s.getPosition("test-1")).isEqualTo(0.0)
        assertThat(s.getDuration("test-1")).isEqualTo(0.0)
        assertThat(s.state.value.recentlyPlayed).doesNotContain("test-1")
        assertThat(s.lastSaved("test-1")).isEqualTo(1_700_000_000_000L)
    }

    @Test fun dismissFromRecentKeepsPosition() = runTest {
        val s = repo()
        s.recordPlay("test-1")
        s.savePosition("test-1", 45.0)
        s.dismissFromRecent("test-1")
        assertThat(s.getPosition("test-1")).isEqualTo(45.0)
        assertThat(s.state.value.recentlyPlayed).doesNotContain("test-1")
    }

    @Test fun dismissDoesNotAffectOtherItems() = runTest {
        val s = repo()
        s.recordPlay("test-1")
        s.recordPlay("test-2")
        s.savePosition("test-1", 30.0)
        s.savePosition("test-2", 60.0)
        s.dismissFromRecent("test-1")
        assertThat(s.state.value.recentlyPlayed).containsExactly("test-2")
        assertThat(s.getPosition("test-2")).isEqualTo(60.0)
    }

    @Test fun recentlyPlayedCapsAt20AndHistoryDoesNot() = runTest {
        val s = repo()
        for (i in 1..25) s.recordPlay("item-$i")
        assertThat(s.state.value.recentlyPlayed).hasSize(20)
        assertThat(s.state.value.recentlyPlayed.first()).isEqualTo("item-25")
        assertThat(s.state.value.recentlyPlayed.last()).isEqualTo("item-6")
        assertThat(s.state.value.allPlayedDiscourseIDs).hasSize(25)
        assertThat(s.state.value.allPlayedDiscourseIDs.first()).isEqualTo("item-25")
    }

    @Test fun playedHistorySurvivesDismissFromRecent() = runTest {
        val s = repo()
        s.recordPlay("test-1")
        s.dismissFromRecent("test-1")
        assertThat(s.state.value.recentlyPlayed).isEmpty()
        assertThat(s.state.value.allPlayedDiscourseIDs).containsExactly("test-1")
    }

    @Test fun zeroAndNonFinitePositionsAreNotSaved() = runTest {
        val s = repo()
        s.savePosition("test-1", 0.0)
        s.savePosition("test-1", Double.NaN)
        s.savePosition("test-1", -4.0)
        assertThat(s.getPosition("test-1")).isEqualTo(0.0)
        assertThat(s.state.value.positions).isEmpty()
    }

    @Test fun saveTimeMovesOnlyWhenThePositionMoves() = runTest {
        val s = repo()
        s.savePosition("d", 100.0)
        assertThat(s.lastSaved("d")).isEqualTo(1_700_000_000_000L)
        clock.advance(10_000)
        s.savePosition("d", 100.4)
        assertThat(s.lastSaved("d")).isEqualTo(1_700_000_000_000L)
        s.savePosition("d", 101.4)
        assertThat(s.lastSaved("d")).isEqualTo(1_700_000_010_000L)
        s.savePosition("d", 50.0, savedAt = 1_600_000_000_000L)
        assertThat(s.lastSaved("d")).isEqualTo(1_600_000_000_000L)
    }

    @Test fun listenedCompleteFeedsRecentlyCompletedAndCount() = runTest {
        val s = repo()
        s.markListenedComplete("series-a-1")
        s.markListenedComplete("series-a-2")
        s.markCompleted("series-b-1")
        assertThat(s.state.value.listenedCompleted).containsExactly("series-a-2", "series-a-1").inOrder()
        assertThat(s.completedCount("series-a")).isEqualTo(2)
        assertThat(s.isCompleted("series-b-1")).isTrue()
        s.unmarkCompleted("series-a-1")
        assertThat(s.completedCount("series-a")).isEqualTo(1)
        assertThat(s.state.value.listenedCompleted).contains("series-a-1")
        s.dismissListenedComplete("series-a-1")
        assertThat(s.state.value.listenedCompleted).containsExactly("series-a-2")
    }

    @Test fun stateSurvivesRelaunch() = runTest {
        val s = repo()
        s.recordPlay("d-1")
        s.savePosition("d-1", 42.0, 300.0)
        s.markListenedComplete("d-2")
        val reloaded = repo()
        assertThat(reloaded.state.value).isEqualTo(s.state.value)
        assertThat(reloaded.lastSaved("d-1")).isEqualTo(1_700_000_000_000L)
    }

    @Test fun localChangesFireForLocalWritesButNotMerges() = runTest {
        val s = repo()
        var count = 0
        backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) { s.localChanges.collect { count++ } }
        s.recordPlay("a")
        s.mergeCloudSnapshot(CloudSnapshot(completed = listOf("z")))
        assertThat(count).isEqualTo(1)
    }

    // CloudSyncTests: mergeList

    @Test fun mergeListPutsCloudFirstThenLocal() {
        assertThat(FilePlaybackStateRepository.mergeList(listOf("a", "b"), listOf("c", "d"), 10)).containsExactly("a", "b", "c", "d").inOrder()
    }

    @Test fun mergeListDeduplicatesKeepingCloudPosition() {
        assertThat(FilePlaybackStateRepository.mergeList(listOf("a", "b"), listOf("b", "c"), 10)).containsExactly("a", "b", "c").inOrder()
    }

    @Test fun mergeListRespectsCap() {
        assertThat(FilePlaybackStateRepository.mergeList(listOf("a", "b", "c"), listOf("d", "e"), 3)).containsExactly("a", "b", "c").inOrder()
    }

    @Test fun mergeListHandlesEmpty() {
        assertThat(FilePlaybackStateRepository.mergeList(emptyList(), listOf("x"), 5)).containsExactly("x")
        assertThat(FilePlaybackStateRepository.mergeList(listOf("y"), emptyList(), 5)).containsExactly("y")
        assertThat(FilePlaybackStateRepository.mergeList(emptyList(), emptyList(), 5)).isEmpty()
    }

    // CloudSyncTests: snapshot merge

    @Test fun mergeKeepsFartherPositionFromCloud() = runTest {
        val s = repo()
        s.savePosition("d-1", 30.0, 600.0)
        s.recordPlay("d-1")
        s.mergeCloudSnapshot(CloudSnapshot(positions = mapOf("d-1" to 120.0), durations = mapOf("d-1" to 600.0)))
        assertThat(s.getPosition("d-1")).isEqualTo(120.0)
    }

    @Test fun cloudPositionIsNotListeningOnThisDevice() = runTest {
        val s = repo()
        val earlier = 1_700_000_000_000L - 86_400_000L
        s.savePosition("d-1", 30.0, 600.0, savedAt = earlier)
        clock.advance(60_000)
        var advanced: Pair<String, Double>? = null
        s.onRemotePositionAdvanced = { id, position -> advanced = id to position }
        s.mergeCloudSnapshot(CloudSnapshot(positions = mapOf("d-1" to 120.0)))
        assertThat(s.getPosition("d-1")).isEqualTo(120.0)
        assertThat(s.getDuration("d-1")).isEqualTo(600.0)
        assertThat(s.lastSaved("d-1")).isEqualTo(earlier)
        assertThat(advanced).isEqualTo("d-1" to 120.0)
    }

    @Test fun mergeDoesNotRewindLocalAheadOfCloud() = runTest {
        val s = repo()
        s.savePosition("d-1", 200.0, 600.0)
        s.recordPlay("d-1")
        s.mergeCloudSnapshot(CloudSnapshot(positions = mapOf("d-1" to 50.0), durations = mapOf("d-1" to 300.0)))
        assertThat(s.getPosition("d-1")).isEqualTo(200.0)
        assertThat(s.getDuration("d-1")).isEqualTo(600.0)
    }

    @Test fun mergeTakesLongerDurationWithoutPosition() = runTest {
        val s = repo()
        s.savePosition("d-1", 200.0, 600.0)
        s.mergeCloudSnapshot(CloudSnapshot(durations = mapOf("d-1" to 610.0, "d-2" to 90.0)))
        assertThat(s.getDuration("d-1")).isEqualTo(610.0)
        assertThat(s.getDuration("d-2")).isEqualTo(90.0)
        assertThat(s.getPosition("d-2")).isEqualTo(0.0)
    }

    @Test fun mergeUnionsCompletedSet() = runTest {
        val s = repo()
        s.markCompleted("local-1")
        s.mergeCloudSnapshot(CloudSnapshot(completed = listOf("cloud-1", "cloud-2")))
        assertThat(s.state.value.completedDiscourseIDs).containsExactly("local-1", "cloud-1", "cloud-2")
    }

    @Test fun mergeRecencyListsPutCloudFirst() = runTest {
        val s = repo()
        s.recordPlay("local-1")
        s.markListenedComplete("done-local")
        s.mergeCloudSnapshot(CloudSnapshot(recentlyPlayed = listOf("cloud-1", "local-1"), listenedCompleted = listOf("done-cloud")))
        assertThat(s.state.value.recentlyPlayed).containsExactly("cloud-1", "local-1").inOrder()
        assertThat(s.state.value.listenedCompleted).containsExactly("done-cloud", "done-local").inOrder()
    }

    @Test fun olderSnapshotWithoutPlayedSeedsHistoryFromRecentAndCompleted() = runTest {
        val s = repo()
        s.recordPlay("mine")
        s.mergeCloudSnapshot(CloudSnapshot(recentlyPlayed = listOf("r1"), completed = listOf("c1"), played = null))
        assertThat(s.state.value.allPlayedDiscourseIDs).containsExactly("r1", "c1", "mine").inOrder()
    }

    @Test fun exportSnapshotIncludesOnlyRecentPositions() = runTest {
        val s = repo()
        s.recordPlay("d-1")
        s.savePosition("d-1", 42.0, 300.0)
        s.savePosition("old", 99.0, 400.0)
        s.markCompleted("c-1")
        val snapshot = s.exportCloudSnapshot()
        assertThat(snapshot.recentlyPlayed).containsExactly("d-1")
        assertThat(snapshot.positions).containsExactly("d-1", 42.0)
        assertThat(snapshot.durations).containsExactly("d-1", 300.0)
        assertThat(snapshot.completed).containsExactly("c-1")
        assertThat(snapshot.played).containsExactly("c-1", "d-1").inOrder()
    }

    @Test fun mergeIsIdempotent() = runTest {
        val s = repo()
        s.recordPlay("d-1")
        s.savePosition("d-1", 90.0, 300.0)
        s.markCompleted("c-1")
        assertThat(s.mergeCloudSnapshot(s.exportCloudSnapshot())).isFalse()
    }

    @Test fun mergeReportsChangeWhenCloudHasNewData() = runTest {
        val s = repo()
        assertThat(s.mergeCloudSnapshot(CloudSnapshot(completed = listOf("new-1")))).isTrue()
        assertThat(s.mergeCloudSnapshot(CloudSnapshot(completed = listOf("new-1")))).isFalse()
    }

    @Test fun twoDevicesConvergeWhicheverMergesFirst() = runTest {
        val a = FilePlaybackStateRepository(folder.newFolder("a"), UnconfinedTestDispatcher(testScheduler), { clock.nowMillis })
        val b = FilePlaybackStateRepository(folder.newFolder("b"), UnconfinedTestDispatcher(testScheduler), { clock.nowMillis })
        a.recordPlay("x"); a.savePosition("x", 50.0, 500.0); a.markCompleted("done-a")
        b.recordPlay("x"); b.savePosition("x", 80.0, 500.0); b.recordPlay("y"); b.markListenedComplete("done-b")
        val fromA = a.exportCloudSnapshot()
        a.mergeCloudSnapshot(b.exportCloudSnapshot())
        b.mergeCloudSnapshot(fromA)
        a.mergeCloudSnapshot(b.exportCloudSnapshot())
        b.mergeCloudSnapshot(a.exportCloudSnapshot())
        assertThat(a.state.value.positions).isEqualTo(b.state.value.positions)
        assertThat(a.state.value.completedDiscourseIDs).isEqualTo(b.state.value.completedDiscourseIDs)
        assertThat(a.state.value.recentlyPlayed).isEqualTo(b.state.value.recentlyPlayed)
        assertThat(a.state.value.listenedCompleted).isEqualTo(b.state.value.listenedCompleted)
        assertThat(a.getPosition("x")).isEqualTo(80.0)
        assertThat(a.mergeCloudSnapshot(b.exportCloudSnapshot())).isFalse()
        assertThat(b.mergeCloudSnapshot(a.exportCloudSnapshot())).isFalse()
    }
}
