package com.agraabhi.oshodiscourses.feature.transcript.text

import com.agraabhi.oshodiscourses.core.domain.transcript.Transcript
import com.google.common.truth.Truth.assertThat
import org.junit.Test

/** Port of iOS `TranscriptPassagesTests`. */
class TranscriptPassagesTest {
    private val first = "The first sentence is long enough to stand on its own here."
    private val second = "The second sentence is also long enough to stand alone today."
    private val third = "A third line follows a line break and is long enough to stand."
    private val next = "Another paragraph begins here with enough letters to count fully."

    private val rows: List<TranscriptRow>
        get() = TranscriptRows.build(
            Transcript(
                "x", "y", 0,
                listOf(
                    Transcript.Paragraph(0, "$first $second\n$third", false),
                    Transcript.Paragraph(1, next, false),
                ),
            ),
            sentences = true,
        )

    @Test
    fun sentenceRowsOfOneParagraphRejoinWithTheirOriginalSpacing() {
        val rows = rows
        assertThat(rows.map { it.text }).containsExactly(first, second, third, next).inOrder()
        assertThat(TranscriptPassages.text(rows.take(3))).isEqualTo("$first $second\n$third")
    }

    @Test
    fun passagesFollowReadingOrderWhateverOrderTheyWerePicked() {
        val rows = rows
        assertThat(TranscriptPassages.text(listOf(rows[3], rows[1]))).isEqualTo("$second\n\n$next")
    }

    @Test
    fun aSkippedRowStartsANewParagraph() {
        val rows = rows
        assertThat(TranscriptPassages.text(listOf(rows[0], rows[2]))).isEqualTo("$first\n\n$third")
    }

    @Test
    fun blockLayoutKeepsAShortParagraphAsOneRow() {
        val single = TranscriptRows.build(Transcript("x", "y", 0, listOf(Transcript.Paragraph(0, "$first $second", false))), sentences = false)
        assertThat(single).hasSize(1)
        assertThat(single[0].isWholeParagraph).isTrue()
        assertThat(TranscriptPassages.text(single)).isEqualTo("$first $second")
    }

    @Test
    fun selectUpToHereFillsFromTheNearestPickedRow() {
        val rows = rows
        assertThat(TranscriptPassages.extending(setOf(rows[0].id), rows[3], rows)).isEqualTo(rows.map { it.id }.toSet())
        // Rows 0 and 3 picked: extending to 2 fills from 3, leaving 1 alone.
        assertThat(TranscriptPassages.extending(setOf(rows[0].id, rows[3].id), rows[2], rows))
            .isEqualTo(setOf(rows[0].id, rows[2].id, rows[3].id))
    }

    @Test
    fun selectUpToHereWithNothingPickedSelectsOnlyThatRow() {
        val rows = rows
        assertThat(TranscriptPassages.extending(emptySet(), rows[1], rows)).isEqualTo(setOf(rows[1].id))
    }

    @Test
    fun sharedTextCarriesTheDiscourse() {
        assertThat(TranscriptPassages.shareText("Be.", "A Bird on the Wing", 3)).isEqualTo("Be.\n\n— Osho, A Bird on the Wing #3")
        assertThat(TranscriptPassages.shareText("Be.", null, null)).isEqualTo("Be.")
    }
}
