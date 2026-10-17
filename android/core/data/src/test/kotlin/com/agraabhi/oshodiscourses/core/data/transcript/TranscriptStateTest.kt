@file:OptIn(ExperimentalCoroutinesApi::class)

package com.agraabhi.oshodiscourses.core.data.transcript

import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptAlignment
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptAnchor
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptReadPosition
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptSyncedState
import com.agraabhi.oshodiscourses.core.testing.FakeClock
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/** Ports the anchor-set and transcript-state parts of `TranscriptTests`. */
class TranscriptStateTest {
    @get:Rule val folder = TemporaryFolder()

    private val t0 = 1_760_000_000_000L
    private val clock = FakeClock(t0)

    private fun TestScope.repo(dir: File = folder.root) =
        FileTranscriptStateRepository(dir, backgroundScope, UnconfinedTestDispatcher(testScheduler), { clock.nowMillis })

    private fun anchor(paragraph: Int, time: Double, createdAt: Long = t0, fraction: Double? = null) = TranscriptAnchor(paragraph, time, createdAt, fraction)

    // TranscriptSyncModelTests: anchor sets

    @Test fun insertingAnchorEvictsWhatItContradicts() {
        val existing = listOf(anchor(2, 100.0), anchor(5, 300.0), anchor(8, 500.0))
        val corrected = TranscriptAnchorRules.inserting(anchor(5, 90.0, t0 + 1_000), existing)
        assertThat(corrected.map { it.paragraph }).containsExactly(5, 8).inOrder()
        assertThat(corrected[0].time).isEqualTo(90.0)
        val squeezed = TranscriptAnchorRules.inserting(anchor(6, 600.0, t0 + 2_000), existing)
        assertThat(squeezed.map { it.paragraph }).containsExactly(2, 5, 6).inOrder()
    }

    @Test fun mergeIsOrderIndependentAndIdempotent() {
        val a = listOf(anchor(2, 100.0), anchor(9, 700.0, t0 + 5_000))
        val b = listOf(anchor(5, 80.0, t0 + 3_000), anchor(2, 100.0))
        val ab = TranscriptAnchorRules.merge(a, b)
        assertThat(TranscriptAnchorRules.merge(b, a)).isEqualTo(ab)
        // p5@80 is newer than p2@100 and evicts it; p9@700, the newest, survives.
        assertThat(ab.map { it.paragraph }).containsExactly(5, 9).inOrder()
        assertThat(TranscriptAnchorRules.merge(ab, a)).isEqualTo(ab)
    }

    @Test fun anchorsOnBlocksOfOneParagraphCoexistWhenOrdered() {
        val early = anchor(4, 100.0, fraction = 0.2)
        val late = anchor(4, 130.0, fraction = 0.8)
        assertThat(TranscriptAnchorRules.inserting(late, listOf(early))).containsExactly(early, late).inOrder()
        val wrong = anchor(4, 90.0, fraction = 0.8)
        assertThat(TranscriptAnchorRules.inserting(wrong, listOf(early))).containsExactly(wrong)
        val legacy = anchor(4, 115.0)
        assertThat(TranscriptAnchorRules.inserting(legacy, listOf(anchor(4, 100.0, fraction = 0.5)))).containsExactly(legacy)
    }

    // TranscriptStateMergeTests

    @Test fun newerReadPositionWinsAndAnchorsUnion() {
        val local = TranscriptSyncedState(listOf(anchor(3, 100.0)), TranscriptReadPosition(10, t0), 200)
        val remote = TranscriptSyncedState(listOf(anchor(30, 900.0, t0 + 1_000)), TranscriptReadPosition(40, t0 + 60_000), 200)
        val merged = FileTranscriptStateRepository.merge(local, remote)
        assertThat(merged.anchors.map { it.paragraph }).containsExactly(3, 30).inOrder()
        assertThat(merged.readPosition?.paragraph).isEqualTo(40)
        assertThat(merged.paragraphCount).isEqualTo(200)
        assertThat(FileTranscriptStateRepository.merge(remote, local)).isEqualTo(merged)
    }

    @Test fun followingAgainBeatsAnOlderPosition() {
        val local = TranscriptSyncedState(readPosition = TranscriptReadPosition.following(t0 + 5_000), paragraphCount = 20)
        val stale = TranscriptSyncedState(readPosition = TranscriptReadPosition(12, t0), paragraphCount = 20)
        assertThat(FileTranscriptStateRepository.merge(local, stale).readPosition?.isFollowing).isTrue()
        assertThat(FileTranscriptStateRepository.merge(stale, local).readPosition?.isFollowing).isTrue()
    }

    @Test fun equalTimesBreakByParagraph() {
        val a = TranscriptSyncedState(readPosition = TranscriptReadPosition(3, t0), paragraphCount = 20)
        val b = TranscriptSyncedState(readPosition = TranscriptReadPosition(7, t0), paragraphCount = 20)
        assertThat(FileTranscriptStateRepository.merge(a, b).readPosition?.paragraph).isEqualTo(7)
        assertThat(FileTranscriptStateRepository.merge(b, a).readPosition?.paragraph).isEqualTo(7)
    }

    @Test fun differentParagraphSplitTakesTheMoreRecentSideWhole() {
        val local = TranscriptSyncedState(listOf(anchor(3, 100.0)), null, 200)
        val remote = TranscriptSyncedState(listOf(anchor(4, 120.0, t0 + 10_000)), null, 210)
        assertThat(FileTranscriptStateRepository.merge(local, remote)).isEqualTo(remote)
        assertThat(FileTranscriptStateRepository.merge(remote, local)).isEqualTo(remote)
    }

    @Test fun missingLocalTakesIncoming() {
        val remote = TranscriptSyncedState(emptyList(), TranscriptReadPosition(7, t0), 50)
        assertThat(FileTranscriptStateRepository.merge(null, remote)).isEqualTo(remote)
    }

    @Test fun anchorsAreCappedToTheNewest40() {
        val many = (0 until 50).map { anchor(it, it * 10.0 + 1, t0 + it) }
        val merged = FileTranscriptStateRepository.merge(TranscriptSyncedState(many.take(25), null, 100), TranscriptSyncedState(many.drop(25), null, 100))
        assertThat(merged.anchors).hasSize(40)
        assertThat(merged.anchors.first().paragraph).isEqualTo(10)
    }

    // Repository

    @Test fun serviceRoundTripsThroughDiskAndInvalidatesOnResplit() = runTest {
        val service = repo()
        service.addAnchor("d1", paragraph = 4, time = 300.0, paragraphCount = 100)
        service.setAlignment("d1", TranscriptAlignment(listOf(0.0, null, 20.0), t0, "test"), paragraphCount = 100)
        val reloaded = repo()
        assertThat(reloaded.state("d1")?.anchors).hasSize(1)
        assertThat(reloaded.state("d1")?.alignment?.matchedCount).isEqualTo(2)
        val resplit = reloaded.state("d1", paragraphCount = 101)
        assertThat(resplit.anchors).isEmpty()
        assertThat(resplit.alignment).isNull()
        assertThat(resplit.paragraphCount).isEqualTo(101)
    }

    @Test fun resplitKeepsAReadPositionThatStillFits() {
        val read = TranscriptReadPosition(50, t0)
        val state = com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptDiscourseState(listOf(anchor(1, 5.0)), read, null, 100)
        assertThat(FileTranscriptStateRepository.reconciled(state, 90).readPosition).isEqualTo(read)
        assertThat(FileTranscriptStateRepository.reconciled(state, 40).readPosition).isNull()
        assertThat(FileTranscriptStateRepository.reconciled(state, 100)).isSameInstanceAs(state)
    }

    @Test fun syncedStatesOnlyIncludeDiscoursesWithUserData() = runTest {
        val service = repo()
        service.setAlignment("aligned-only", TranscriptAlignment(listOf(0.0), t0, "test"), paragraphCount = 1)
        service.addAnchor("anchored", paragraph = 0, time = 5.0, paragraphCount = 3)
        val synced = service.syncedStates()
        assertThat(synced.keys).containsExactly("anchored")
        assertThat(synced["anchored"]?.anchors).hasSize(1)
    }

    @Test fun readPositionSavesAfterAPauseAndNotifies() = runTest {
        val service = repo()
        var pushes = 0
        backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) { service.localChanges.collect { pushes++ } }
        service.setReadPosition("d1", paragraph = 12, paragraphCount = 40)
        service.setReadPosition("d1", paragraph = 13, paragraphCount = 40)
        assertThat(service.state("d1")?.readPosition).isEqualTo(TranscriptReadPosition(13, t0))
        assertThat(File(folder.root, FileTranscriptStateRepository.FILE_NAME).exists()).isFalse()
        advanceTimeBy(999)
        runCurrent()
        assertThat(pushes).isEqualTo(0)
        advanceTimeBy(2)
        runCurrent()
        assertThat(pushes).isEqualTo(1)
        assertThat(repo().state("d1")?.readPosition?.paragraph).isEqualTo(13)
    }

    @Test fun followingAgainIsATimestampedTombstone() = runTest {
        val service = repo()
        service.clearReadPosition("d1")
        assertThat(service.state("d1")).isNull()
        service.setReadPosition("d1", paragraph = 5, paragraphCount = 40)
        clock.advance(30_000)
        service.clearReadPosition("d1")
        service.flush()
        val read = repo().state("d1")?.readPosition
        assertThat(read?.isFollowing).isTrue()
        assertThat(read?.updatedAt).isEqualTo(t0 + 30_000)
    }

    @Test fun mergeSyncedReplaysAnchorsAndDropsAlignmentForAnotherSplit() = runTest {
        val service = repo()
        service.addAnchor("d1", paragraph = 2, time = 100.0, paragraphCount = 50)
        service.setAlignment("d1", TranscriptAlignment(listOf(0.0), t0, "test"), paragraphCount = 50)
        val remote = TranscriptSyncedState(listOf(anchor(5, 80.0, t0 + 3_000)), TranscriptReadPosition(9, t0 + 4_000), 50)
        assertThat(service.mergeSynced(mapOf("d1" to remote))).isTrue()
        assertThat(service.state("d1")?.anchors?.map { it.paragraph }).containsExactly(5)
        assertThat(service.state("d1")?.alignment).isNotNull()
        assertThat(service.mergeSynced(mapOf("d1" to remote))).isFalse()

        val resplit = TranscriptSyncedState(listOf(anchor(1, 10.0, t0 + 9_000)), null, 60)
        assertThat(service.mergeSynced(mapOf("d1" to resplit))).isTrue()
        assertThat(service.state("d1")?.alignment).isNull()
        assertThat(service.state("d1")?.paragraphCount).isEqualTo(60)
        assertThat(repo().state("d1")?.paragraphCount).isEqualTo(60)
    }

    @Test fun mergeDoesNotNotify() = runTest {
        val service = repo()
        var pushes = 0
        backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) { service.localChanges.collect { pushes++ } }
        service.mergeSynced(mapOf("d1" to TranscriptSyncedState(listOf(anchor(1, 1.0)), null, 5)))
        assertThat(pushes).isEqualTo(0)
        service.addAnchor("d1", paragraph = 3, time = 30.0, paragraphCount = 5)
        assertThat(pushes).isEqualTo(1)
    }
}
