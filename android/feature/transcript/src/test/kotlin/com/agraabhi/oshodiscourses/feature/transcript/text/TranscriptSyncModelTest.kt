package com.agraabhi.oshodiscourses.feature.transcript.text

import com.agraabhi.oshodiscourses.core.domain.transcript.TimingSource
import com.agraabhi.oshodiscourses.core.domain.transcript.Transcript
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptAnchor
import com.google.common.truth.Truth.assertThat
import org.junit.Test
import kotlin.math.abs

/** Port of iOS `TranscriptSyncModelTests` and the model parts of `TranscriptBlocksTests`. */
class TranscriptSyncModelTest {
    private fun paragraphs(vararg lengths: Int) = lengths.mapIndexed { i, n -> Transcript.Paragraph(i, "a".repeat(n), isEmphasis = false) }

    private fun anchor(paragraph: Int, time: Double, createdAt: Long = 0, fraction: Double? = null) =
        TranscriptAnchor(paragraph, time, createdAt, fraction)

    private fun near(actual: Double, expected: Double) = assertThat(abs(actual - expected)).isLessThan(0.001)

    @Test
    fun withoutAnchorsTimeIsProportionalToText() {
        val model = TranscriptSyncModel(paragraphs(100, 100, 200), 400.0)
        assertThat(model.startTime(0)).isEqualTo(0.0)
        assertThat(model.startTime(1)).isEqualTo(100.0)
        assertThat(model.startTime(2)).isEqualTo(200.0)
        assertThat(model.paragraphAt(0.0)).isEqualTo(0)
        assertThat(model.paragraphAt(150.0)).isEqualTo(1)
        assertThat(model.paragraphAt(250.0)).isEqualTo(2)
        assertThat(model.paragraphAt(10_000.0)).isEqualTo(2)
        assertThat(model.paragraphAt(-5.0)).isEqualTo(0)
    }

    @Test
    fun whitespaceDoesNotWeighParagraphs() {
        val letters = "a".repeat(120)
        val spaced = Transcript.Paragraph(0, letters.toList().joinToString(" "), false)
        val dense = Transcript.Paragraph(1, letters, false)
        assertThat(TranscriptSyncModel(listOf(spaced, dense), 100.0).startTime(1)).isEqualTo(50.0)
    }

    @Test
    fun shortVersesGetAMinimumShareOfTime() {
        val verse = Transcript.Paragraph(0, "नदी बहती", false)
        val prose = Transcript.Paragraph(1, "b".repeat(400), false)
        assertThat(TranscriptSyncModel(listOf(verse, prose), 450.0).startTime(1)).isEqualTo(50.0)
    }

    @Test
    fun anchorPinsParagraphMidpointAndBendsTheMapAroundIt() {
        val base = TranscriptSyncModel(paragraphs(100, 100, 100, 100), 400.0)
        val model = base.with(listOf(base.knot(anchor(1, 250.0))!!))
        assertThat(model.paragraphAt(250.0)).isEqualTo(1)
        near(model.startTime(1), 250 * (100.0 / 150.0))
        near(model.startTime(3), 250 + 150 * (150.0 / 250.0))
        assertThat(model.startTime(0)).isEqualTo(0.0)
        assertThat(model.timeAtPosition(400.0)).isEqualTo(400.0)
    }

    @Test
    fun contradictoryKnotsAreDroppedKeepingTheMapMonotonic() {
        val base = TranscriptSyncModel(paragraphs(100, 100, 100, 100), 400.0)
        val good = base.knot(1, 100.0)!!
        val backwards = base.knot(2, 50.0)!!
        val outside = TranscriptSyncModel.Knot(350.0, 900.0)
        val model = base.with(listOf(backwards, good, outside))
        assertThat(model.knots).hasSize(3)
        assertThat(model.knots[1]).isEqualTo(good)
        assertThat(model.knots.map { it.time }).isInStrictOrder()
    }

    @Test
    fun anchorsOverrideTheAlignedStartsTheyContradict() {
        val base = TranscriptSyncModel(paragraphs(100, 100, 100, 100), 400.0)
        val knots = base.knots(listOf(0.0, 100.0, 200.0, 300.0), listOf(anchor(1, 250.0)))
        assertThat(knots.map { it.position }).containsExactly(0.0, 100.0, 300.0, 150.0).inOrder()
        val model = base.with(knots)
        assertThat(model.paragraphAt(250.0)).isEqualTo(1)
        assertThat(model.startTime(3)).isEqualTo(300.0)
        assertThat(base.knots(listOf(null, 100.0, null, 300.0), emptyList()).map { it.time }).containsExactly(100.0, 300.0).inOrder()
    }

    @Test
    fun degenerateInputsDoNotTrap() {
        val empty = TranscriptSyncModel(emptyList(), 100.0)
        assertThat(empty.paragraphAt(50.0)).isEqualTo(0)
        assertThat(empty.startTime(3)).isEqualTo(0.0)
        assertThat(empty.time(0, 0.5)).isEqualTo(0.0)
        val noDuration = TranscriptSyncModel(paragraphs(10, 10), 0.0)
        assertThat(noDuration.paragraphAt(50.0)).isEqualTo(1)
        assertThat(noDuration.startTime(1)).isEqualTo(0.0)
    }

    @Test
    fun insertingAnchorEvictsWhatItContradicts() {
        val existing = listOf(anchor(2, 100.0), anchor(5, 300.0), anchor(8, 500.0))
        val corrected = TranscriptSyncModel.inserting(anchor(5, 90.0, createdAt = 1), existing)
        assertThat(corrected.map { it.paragraph }).containsExactly(5, 8).inOrder()
        assertThat(corrected[0].time).isEqualTo(90.0)
        val squeezed = TranscriptSyncModel.inserting(anchor(6, 600.0, createdAt = 2), existing)
        assertThat(squeezed.map { it.paragraph }).containsExactly(2, 5, 6).inOrder()
    }

    @Test
    fun mergeIsOrderIndependent() {
        val a = listOf(anchor(2, 100.0, 0), anchor(9, 700.0, 5_000))
        val b = listOf(anchor(5, 80.0, 3_000), anchor(2, 100.0, 0))
        val ab = TranscriptSyncModel.merge(a, b)
        assertThat(ab).isEqualTo(TranscriptSyncModel.merge(b, a))
        assertThat(ab.map { it.paragraph }).containsExactly(5, 9).inOrder()
        assertThat(TranscriptSyncModel.merge(ab, a)).isEqualTo(ab)
    }

    @Test
    fun anchorsOnRowsOfOneParagraphCoexistWhenOrdered() {
        val early = anchor(4, 100.0, fraction = 0.2)
        val late = anchor(4, 130.0, fraction = 0.8)
        assertThat(TranscriptSyncModel.inserting(late, listOf(early))).containsExactly(early, late).inOrder()
        val wrong = anchor(4, 90.0, fraction = 0.8)
        assertThat(TranscriptSyncModel.inserting(wrong, listOf(early))).containsExactly(wrong)
        val legacy = anchor(4, 115.0)
        assertThat(TranscriptSyncModel.inserting(legacy, listOf(anchor(4, 100.0, fraction = 0.5)))).containsExactly(legacy)
    }

    @Test
    fun fractionMapsThroughTheModel() {
        val base = TranscriptSyncModel(paragraphs(100, 100, 100, 100), 400.0)
        assertThat(base.time(1, 0.5)).isEqualTo(150.0)
        assertThat(base.fraction(150.0, 1)).isEqualTo(0.5)
        assertThat(base.fraction(350.0, 1)).isEqualTo(1.0)
        val anchored = base.with(listOf(base.knot(anchor(1, 250.0, fraction = 0.25))!!))
        assertThat(anchored.knots[1].position).isEqualTo(125.0)
    }

    @Test
    fun buildUsesAlignedStartsOnlyWhenGiven() {
        val estimate = TranscriptSyncModel.build(paragraphs(100, 100), 200.0, emptyList())
        assertThat(estimate.source).isEqualTo(TimingSource.ESTIMATE)
        val aligned = TranscriptSyncModel.build(paragraphs(100, 100), 200.0, emptyList(), listOf(0.0, 150.0))
        assertThat(aligned.source).isEqualTo(TimingSource.SHIPPED_ALIGNMENT)
        assertThat(aligned.startTime(1)).isEqualTo(150.0)
    }
}
