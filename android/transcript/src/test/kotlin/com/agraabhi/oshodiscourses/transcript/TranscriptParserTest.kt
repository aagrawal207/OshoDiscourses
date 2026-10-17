package com.agraabhi.oshodiscourses.transcript

import com.agraabhi.oshodiscourses.core.domain.transcript.Transcript
import com.google.common.truth.Truth.assertThat
import org.junit.Test

class TranscriptParserTest {
    @Test
    fun englishQuotedQuestionBecomesOneEmphasisBlock() {
        val html = "<strong>BELOVED MASTER,</strong><br><strong>THE JAPANESE MASTER NAN-IN GAVE AUDIENCE\r\nTO A PROFESSOR OF PHILOSOPHY.\r\nSTOP!</strong><br>You have come to an even more dangerous person than Nan-in.<br>The story is beautiful."
        val paragraphs = TranscriptParser.paragraphs(html)
        assertThat(paragraphs).hasSize(3)
        assertThat(paragraphs[0].isEmphasis).isTrue()
        assertThat(paragraphs[0].text).isEqualTo("BELOVED MASTER,\nTHE JAPANESE MASTER NAN-IN GAVE AUDIENCE\nTO A PROFESSOR OF PHILOSOPHY.\nSTOP!")
        assertThat(paragraphs[1].isEmphasis).isFalse()
        assertThat(paragraphs[1].text).isEqualTo("You have come to an even more dangerous person than Nan-in.")
        assertThat(paragraphs[2].text).isEqualTo("The story is beautiful.")
        assertThat(paragraphs.map { it.index }).containsExactly(0, 1, 2).inOrder()
    }

    @Test
    fun hindiVersesSplitOnBreaksAndTrailingRuleIsDropped() {
        val html = "जनक उवाच।<br><br>कथं ज्ञानमवाप्नोति कथं मुक्तिर्भविष्यति।<br>वैराग्यं च कथं प्राप्तमेतद् ब्रूहि मम प्रभो।। 1।।<br><br>एक अनूठी यात्रा पर हम निकलते हैं।<br>हरि ॐ तत्सत्\u200C!<br><hr>"
        val paragraphs = TranscriptParser.paragraphs(html)
        assertThat(paragraphs.map { it.text }).containsExactly(
            "जनक उवाच।",
            "कथं ज्ञानमवाप्नोति कथं मुक्तिर्भविष्यति।",
            "वैराग्यं च कथं प्राप्तमेतद् ब्रूहि मम प्रभो।। 1।।",
            "एक अनूठी यात्रा पर हम निकलते हैं।",
            "हरि ॐ तत्सत्\u200C!",
        ).inOrder()
        assertThat(paragraphs.none { it.isEmphasis }).isTrue()
    }

    @Test
    fun siteSpecificQuoteTagsAreEmphasisAndSeparateBlocksStaySeparate() {
        val html = "Try to understand it.<br><q>CONFUCIUS WAS LOOKING AT THE CATARACT.\r\nIT FALLS FROM A HEIGHT.</q><br><q>YET CONFUCIUS SAW AN OLD MAN GO IN.</q><br>भगवान,<cr>मैंने उपवास के संबंध में कुछ कहा।</cr><br>तो सबसे पहले।"
        val paragraphs = TranscriptParser.paragraphs(html)
        assertThat(paragraphs).hasSize(5)
        assertThat(paragraphs[1].isEmphasis).isTrue()
        assertThat(paragraphs[1].text).startsWith("CONFUCIUS")
        assertThat(paragraphs[1].text).contains("\n")
        // Two adjacent <q> blocks separated only by <br> read as one quoted passage.
        assertThat(paragraphs[1].text).endsWith("GO IN.")
        assertThat(paragraphs[2].text).isEqualTo("भगवान,")
        assertThat(paragraphs[2].isEmphasis).isFalse()
        assertThat(paragraphs[3].isEmphasis).isTrue()
        assertThat(paragraphs[3].text).isEqualTo("मैंने उपवास के संबंध में कुछ कहा।")
        assertThat(paragraphs[4].text).isEqualTo("तो सबसे पहले।")
    }

    @Test
    fun blankLineSeparatesTwoQuotedBlocks() {
        val paragraphs = TranscriptParser.paragraphs("<q>FIRST QUESTION.</q><br><br><q>SECOND QUESTION.</q><br>Answer.")
        assertThat(paragraphs.map { it.text to it.isEmphasis }).containsExactly(
            "FIRST QUESTION." to true,
            "SECOND QUESTION." to true,
            "Answer." to false,
        ).inOrder()
    }

    @Test
    fun inlineItalicsKeepTheirTextAndBlockTagsSplitMidLine() {
        val html = "<i>Maitreya</i> means the friend.<br>भगवान,<strong>क्या उपवास से मेरा विरोध है?</strong>"
        val paragraphs = TranscriptParser.paragraphs(html)
        assertThat(paragraphs.map { it.text }).containsExactly("Maitreya means the friend.", "भगवान,", "क्या उपवास से मेरा विरोध है?").inOrder()
        assertThat(paragraphs.map { it.isEmphasis }).containsExactly(false, false, true).inOrder()
    }

    @Test
    fun entitiesAndBlankMarkupAreHandled() {
        assertThat(TranscriptParser.decodeEntities("Tom &amp; Jerry &lt;3 &#39;yes&#39; &#x2014; &hellip; &unknown;"))
            .isEqualTo("Tom & Jerry <3 'yes' \u2014 \u2026 &unknown;")
        assertThat(TranscriptParser.decodeEntities("&#x1F600; &#xD800; and & alone; &verylongentityname;")).isEqualTo("\uD83D\uDE00 &#xD800; and & alone; &verylongentityname;")
        assertThat(TranscriptParser.paragraphs("<p><br><hr></p>")).isEmpty()
        assertThat(TranscriptParser.paragraphs("")).isEmpty()
        assertThat(TranscriptParser.paragraphs("Osho")).hasSize(1)
    }

    @Test
    fun loneCarriageReturnsAndUppercaseTagsBreakLines() {
        val paragraphs = TranscriptParser.paragraphs("One\rTwo<BR/>Three<STRONG>FOUR</STRONG>")
        assertThat(paragraphs.map { it.text }).containsExactly("One", "Two", "Three", "FOUR").inOrder()
        assertThat(paragraphs.last().isEmphasis).isTrue()
    }

    @Test
    fun wordCountIgnoresMarkupArtifacts() {
        val transcript = Transcript("x", "y", 0L, TranscriptParser.paragraphs("One two<br>three\r\nfour  five"))
        assertThat(transcript.wordCount).isEqualTo(5)
    }

    // Paragraph counts come from the shipped AlignmentCatalog, which iOS built from the same pages.
    @Test
    fun realEnglishPageMatchesTheIosParagraphSplit() {
        val html = checkNotNull(TranscriptFetcher.descriptionFromAPIResponse(Fixtures.read("a-bird-on-the-wing-01.api.json")))
        val paragraphs = TranscriptParser.paragraphs(html)
        assertThat(paragraphs).hasSize(93)
        assertThat(paragraphs[0].isEmphasis).isTrue()
        assertThat(paragraphs[0].text).startsWith("BELOVED MASTER,\nTHE JAPANESE MASTER NAN-IN GAVE AUDIENCE\nTO A PROFESSOR OF PHILOSOPHY.")
        assertThat(paragraphs[0].text).endsWith("UNLESS YOU FIRST EMPTY YOUR CUP?")
        assertThat(paragraphs[1].isEmphasis).isFalse()
        assertThat(paragraphs[1].text).startsWith("You have come to an even more dangerous person than Nan-in")
        assertThat(paragraphs.map { it.index }).isEqualTo(paragraphs.indices.toList())
        assertThat(paragraphs.none { it.text.contains('<') || it.text.contains('\r') }).isTrue()
        assertThat(Transcript("d", "s", 0L, paragraphs).wordCount).isAtLeast(8_000)
    }

    @Test
    fun realHindiPageMatchesTheIosParagraphSplit() {
        val html = checkNotNull(TranscriptFetcher.descriptionFromPageHTML(Fixtures.read("ashtavakra-maha-geeta-01.page.html")))
        val paragraphs = TranscriptParser.paragraphs(html)
        assertThat(paragraphs).hasSize(239)
        assertThat(paragraphs.take(3).map { it.text }).containsExactly(
            "जनक उवाच।",
            "कथं ज्ञानमवाप्नोति कथं मुक्तिर्भविष्यति।",
            "वैराग्यं च कथं प्राप्तमेतद् ब्रूहि मम प्रभो।। 1।।",
        ).inOrder()
        assertThat(paragraphs.none { it.isEmphasis }).isTrue()
        assertThat(paragraphs.none { it.text.contains('<') || it.text.isBlank() }).isTrue()
    }
}
