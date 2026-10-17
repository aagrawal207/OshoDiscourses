package com.agraabhi.oshodiscourses.feature.transcript.text

import com.agraabhi.oshodiscourses.core.domain.transcript.Transcript
import com.google.common.truth.Truth.assertThat
import org.junit.Test
import kotlin.math.abs

/** Port of iOS `TranscriptSentencesTests` and `TranscriptBlocksTests`. */
class TranscriptTextTest {
    private fun parts(text: String, ranges: List<TextSpan>) = ranges.map { text.slice(it) }

    @Test
    fun splitsOnTerminatorsAndKeepsClosingQuotes() {
        val text = "She said: \"Stop!\" Then she went... Really? Yes."
        assertThat(parts(text, TranscriptSentences.ranges(text)))
            .containsExactly("She said: \"Stop!\"", "Then she went...", "Really?", "Yes.").inOrder()
    }

    @Test
    fun devanagariDandasAndVerseLinesSplit() {
        val text = "नदी बहती है।\nसूरज उगता है॥ यह सुबह है।"
        assertThat(parts(text, TranscriptSentences.ranges(text))).containsExactly("नदी बहती है।", "सूरज उगता है॥", "यह सुबह है।").inOrder()
        val numbered = "पानी बहता है।। 14।। हवा चलती है।"
        assertThat(parts(numbered, TranscriptSentences.ranges(numbered))).containsExactly("पानी बहता है।। 14।।", "हवा चलती है।").inOrder()
    }

    @Test
    fun gluedStopsAndUnterminatedTailsAreHandled() {
        val text = "Version 3.5 is out. See e.g. the notes"
        assertThat(parts(text, TranscriptSentences.ranges(text))).containsExactly("Version 3.5 is out.", "See e.g. the notes").inOrder()
        val quoted = "If a child asks \"What is rain?\" it shows she is curious. Really? yes."
        assertThat(parts(quoted, TranscriptSentences.ranges(quoted)))
            .containsExactly("If a child asks \"What is rain?\" it shows she is curious.", "Really? yes.").inOrder()
        assertThat(TranscriptSentences.ranges("")).isEmpty()
        assertThat(TranscriptSentences.ranges("no stop")).hasSize(1)
    }

    @Test
    fun indexFollowsCharacterShare() {
        val text = "Short. A much much much longer second sentence here. End."
        assertThat(TranscriptSentences.index(0.0, text)).isEqualTo(0)
        assertThat(TranscriptSentences.index(0.5, text)).isEqualTo(1)
        assertThat(TranscriptSentences.index(0.99, text)).isEqualTo(2)
        assertThat(TranscriptSentences.index(1.5, text)).isEqualTo(2)
        assertThat(TranscriptSentences.index(0.5, "One sentence only")).isEqualTo(0)
    }

    private val sentence = "This is one sentence of roughly sixty characters for the test. "

    @Test
    fun shortParagraphsStayWhole() {
        assertThat(TranscriptBlocks.ranges(sentence.repeat(5).trim())).hasSize(1)
        assertThat(TranscriptBlocks.ranges("")).isEmpty()
        assertThat(TranscriptBlocks.ranges("word ".repeat(200))).hasSize(1)
    }

    @Test
    fun longParagraphsSplitIntoEvenSentenceAlignedBlocks() {
        val text = sentence.repeat(15).trim()
        val ranges = TranscriptBlocks.ranges(text)
        assertThat(ranges).hasSize(3)
        for (r in ranges) {
            assertThat(text.slice(r)).endsWith(".")
            assertThat(text.slice(r)).startsWith("This")
        }
        assertThat(ranges.first().start).isEqualTo(0)
        assertThat(ranges.last().end).isEqualTo(text.length)
        ranges.zipWithNext { a, b -> assertThat(text.substring(a.end, b.start).trim()).isEmpty() }
        val shares = TranscriptBlocks.fractions(ranges, text)
        assertThat(shares.first().first).isEqualTo(0.0)
        assertThat(shares.last().second).isEqualTo(1.0)
        assertThat(abs(shares[1].first - 1.0 / 3)).isLessThan(0.05)
    }

    @Test
    fun sentenceLayoutGivesOneRowPerSentenceAndFoldsFragments() {
        val text = "The river runs to the sea in the quiet morning. Why? Why does it run? " +
            "The wind moves across the open field and bends the grass. It is the same! " +
            "The stars come out one by one over the far hills at night."
        assertThat(parts(text, TranscriptBlocks.sentenceRanges(text))).containsExactly(
            "The river runs to the sea in the quiet morning. Why? Why does it run?",
            "The wind moves across the open field and bends the grass. It is the same!",
            "The stars come out one by one over the far hills at night.",
        ).inOrder()
        assertThat(TranscriptBlocks.sentenceRanges("")).isEmpty()
        assertThat(TranscriptBlocks.sentenceRanges("Short.")).hasSize(1)
    }

    @Test
    fun noTinyRemainderBlock() {
        val text = sentence.repeat(8) + "Short end."
        assertThat(TranscriptBlocks.ranges(text).map { text.slice(it).length }.all { it > 100 }).isTrue()
    }

    @Test
    fun rowAtPicksTheLastRowStartedAndSentenceIndexIsRelative() {
        val transcript = Transcript("x", "y", 0, listOf(Transcript.Paragraph(0, sentence.repeat(15).trim(), false)))
        val rows = TranscriptRows.build(transcript, sentences = false)
        assertThat(rows).hasSize(3)
        assertThat(TranscriptRows.rowAt(rows, 0, 0.0)?.id).isEqualTo(RowID(0, 0))
        assertThat(TranscriptRows.rowAt(rows, 0, 0.5)?.id).isEqualTo(RowID(0, 1))
        assertThat(TranscriptRows.rowAt(rows, 0, 1.0)?.id).isEqualTo(RowID(0, 2))
        assertThat(TranscriptRows.rowAt(rows, 3, 0.5)).isNull()
        assertThat(TranscriptRows.sentenceIndex(rows[1], rows[1].start)).isEqualTo(0)
        assertThat(TranscriptRows.sentenceIndex(rows[1], rows[1].end - 0.001)).isEqualTo(4)
    }

    @Test
    fun searchIsCaseAndDiacriticInsensitiveAndMapsBackToTheSource() {
        val text = "A Café by the sea. The CAFE is open."
        val matches = TranscriptSearch.matches(text, "cafe")
        assertThat(matches.map { text.slice(it) }).containsExactly("Café", "CAFE").inOrder()
        assertThat(TranscriptSearch.contains(text, "SEA")).isTrue()
        assertThat(TranscriptSearch.normalizedQuery(" a ")).isNull()
        assertThat(TranscriptSearch.normalizedQuery(" ab ")).isEqualTo("ab")
        // Devanagari marks distinguish words, so they never fold away.
        assertThat(TranscriptSearch.contains("नदी बहती है", "नद")).isTrue()
        assertThat(TranscriptSearch.contains("नदी बहती है", "नदि")).isFalse()
    }
}
