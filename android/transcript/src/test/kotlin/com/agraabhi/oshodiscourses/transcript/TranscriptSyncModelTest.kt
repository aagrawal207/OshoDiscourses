package com.agraabhi.oshodiscourses.transcript

import com.agraabhi.oshodiscourses.core.domain.transcript.TimingSource
import com.agraabhi.oshodiscourses.core.domain.transcript.Transcript
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptAnchor
import com.google.common.truth.Truth.assertThat
import org.junit.Test

class TranscriptSyncModelTest {
    private fun paragraphs(vararg lengths: Int) = lengths.mapIndexed { i, n -> Transcript.Paragraph(i, "a".repeat(n), isEmphasis = false) }

    private fun anchor(paragraph: Int, time: Double, fraction: Double? = null) = TranscriptAnchor(paragraph, time, createdAt = 0L, fraction = fraction)

    @Test
    fun withoutAnchorsTimeIsProportionalToText() {
        val model = TranscriptSyncModel(paragraphs(100, 100, 200), duration = 400.0)
        assertThat(model.startTime(0)).isEqualTo(0.0)
        assertThat(model.startTime(1)).isEqualTo(100.0)
        assertThat(model.startTime(2)).isEqualTo(200.0)
        assertThat(model.paragraphAt(0.0)).isEqualTo(0)
        assertThat(model.paragraphAt(150.0)).isEqualTo(1)
        assertThat(model.paragraphAt(250.0)).isEqualTo(2)
        assertThat(model.paragraphAt(10_000.0)).isEqualTo(2)
        assertThat(model.paragraphAt(-5.0)).isEqualTo(0)
        assertThat(model.source).isEqualTo(TimingSource.ESTIMATE)
        assertThat(model.paragraphCount).isEqualTo(3)
    }

    @Test
    fun whitespaceDoesNotWeighParagraphs() {
        val letters = "a".repeat(120)
        val spaced = Transcript.Paragraph(0, letters.toList().joinToString(" "), isEmphasis = false)
        val dense = Transcript.Paragraph(1, letters, isEmphasis = false)
        val nbsp = Transcript.Paragraph(2, letters.toList().joinToString("\u00A0"), isEmphasis = false)
        val model = TranscriptSyncModel(listOf(spaced, dense, nbsp), duration = 360.0)
        assertThat(model.startTime(1)).isEqualTo(120.0)
        assertThat(model.startTime(2)).isEqualTo(240.0)
    }

    @Test
    fun shortVersesGetAMinimumShareOfTime() {
        // An 8-character sutra before 400 characters of prose would own 2% of the time without the floor.
        val verse = Transcript.Paragraph(0, "जनक उवाच", isEmphasis = false)
        val prose = Transcript.Paragraph(1, "b".repeat(400), isEmphasis = false)
        val model = TranscriptSyncModel(listOf(verse, prose), duration = 450.0)
        assertThat(model.startTime(1)).isEqualTo(50.0)
    }

    @Test
    fun devanagariIsWeighedByScalarsNotGlyphs() {
        // "कि" is one glyph of two scalars; 60 of them weigh 120, like iOS unicodeScalars.
        val hindi = Transcript.Paragraph(0, "कि".repeat(60), isEmphasis = false)
        val latin = Transcript.Paragraph(1, "a".repeat(120), isEmphasis = false)
        assertThat(TranscriptSyncModel(listOf(hindi, latin), duration = 240.0).startTime(1)).isEqualTo(120.0)
    }

    @Test
    fun anchorPinsParagraphMidpointAndBendsTheMapAroundIt() {
        val base = TranscriptSyncModel(paragraphs(100, 100, 100, 100), duration = 400.0)
        // Paragraph 1 (characters 100-200, midpoint 150) was actually heard at t=250.
        val model = base.with(listOf(checkNotNull(base.knot(anchor(1, 250.0)))))
        assertThat(model.paragraphAt(250.0)).isEqualTo(1)
        // Slower before the anchor (150 characters over 250 s), faster after (250 in 150 s).
        assertThat(model.startTime(1)).isWithin(0.001).of(250 * (100.0 / 150.0))
        assertThat(model.startTime(3)).isWithin(0.001).of(250 + 150 * (150.0 / 250.0))
        assertThat(model.startTime(0)).isEqualTo(0.0)
        assertThat(model.timeAtPosition(400.0)).isEqualTo(400.0)
    }

    @Test
    fun contradictoryKnotsAreDroppedKeepingTheMapMonotonic() {
        val base = TranscriptSyncModel(paragraphs(100, 100, 100, 100), duration = 400.0)
        val good = checkNotNull(base.knot(paragraph = 1, startingAt = 100.0))
        val backwards = checkNotNull(base.knot(paragraph = 2, startingAt = 50.0))
        val outside = TranscriptSyncModel.Knot(position = 350.0, time = 900.0)
        val model = base.with(listOf(backwards, good, outside))
        assertThat(model.knots).hasSize(3)
        assertThat(model.knots[1]).isEqualTo(good)
        assertThat(model.knots.map { it.time }).isInStrictOrder()
        assertThat(base.knot(paragraph = 4, startingAt = 1.0)).isNull()
        assertThat(base.knot(anchor(-1, 1.0))).isNull()
    }

    @Test
    fun anchorsOverrideTheAlignedStartsTheyContradict() {
        val base = TranscriptSyncModel(paragraphs(100, 100, 100, 100), duration = 400.0)
        // Paragraph 1 playing at t=250 rules out paragraph 2 starting at 200; paragraph 1 at 100 survives.
        val knots = base.knots(alignedStarts = listOf(0.0, 100.0, 200.0, 300.0), anchors = listOf(anchor(1, 250.0)))
        assertThat(knots.map { it.position }).containsExactly(0.0, 100.0, 300.0, 150.0).inOrder()
        val model = base.with(knots)
        assertThat(model.paragraphAt(250.0)).isEqualTo(1)
        assertThat(model.startTime(3)).isEqualTo(300.0)
        assertThat(base.knots(listOf(null, 100.0, null, 300.0), emptyList()).map { it.time }).containsExactly(100.0, 300.0).inOrder()
    }

    @Test
    fun degenerateInputsDoNotTrap() {
        val empty = TranscriptSyncModel(emptyList(), duration = 100.0)
        assertThat(empty.paragraphAt(50.0)).isEqualTo(0)
        assertThat(empty.startTime(3)).isEqualTo(0.0)
        assertThat(empty.time(0, 0.5)).isEqualTo(0.0)
        assertThat(empty.fraction(10.0, 0)).isEqualTo(0.0)
        val noDuration = TranscriptSyncModel(paragraphs(10, 10), duration = 0.0)
        assertThat(noDuration.paragraphAt(50.0)).isEqualTo(1)
        assertThat(noDuration.startTime(1)).isEqualTo(0.0)
        assertThat(TranscriptSyncModel(paragraphs(10), duration = -5.0).duration).isEqualTo(0.0)
    }

    @Test
    fun fractionMapsThroughTheModel() {
        val base = TranscriptSyncModel(paragraphs(100, 100, 100, 100), duration = 400.0)
        assertThat(base.time(1, 0.5)).isEqualTo(150.0)
        assertThat(base.fraction(150.0, 1)).isEqualTo(0.5)
        assertThat(base.fraction(350.0, 1)).isEqualTo(1.0)
        assertThat(base.fraction(10.0, 7)).isEqualTo(0.0)
        val anchored = base.with(listOf(checkNotNull(base.knot(anchor(1, 250.0, fraction = 0.25)))))
        assertThat(anchored.knots[1].position).isEqualTo(125.0)
    }

    @Test
    fun withKeepsTheSourceUnlessGivenOne() {
        val base = TranscriptSyncModel(paragraphs(100, 100), duration = 200.0)
        assertThat(base.with(emptyList()).source).isEqualTo(TimingSource.ESTIMATE)
        assertThat(base.with(emptyList(), TimingSource.SHIPPED_ALIGNMENT).source).isEqualTo(TimingSource.SHIPPED_ALIGNMENT)
    }
}
