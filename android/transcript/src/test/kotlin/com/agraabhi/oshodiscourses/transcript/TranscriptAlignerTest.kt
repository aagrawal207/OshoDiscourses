package com.agraabhi.oshodiscourses.transcript

import com.agraabhi.oshodiscourses.core.domain.transcript.Transcript
import com.google.common.truth.Truth.assertThat
import org.junit.Test
import java.text.Normalizer
import kotlin.math.abs

class TranscriptAlignerTest {
    /** Synthetic recording: the transcript's own words, one per 0.5 s, with recogniser noise mixed in. */
    private fun speak(paragraphs: List<Transcript.Paragraph>, dropEvery: Int = 0, misheard: Set<String> = emptySet()): List<RecognizedWord> {
        val words = mutableListOf<RecognizedWord>()
        var t = 0.0
        var n = 0
        for (p in paragraphs) {
            for (token in p.text.split(' ').filter { it.isNotEmpty() }) {
                n += 1
                if (dropEvery > 0 && n % dropEvery == 0) {
                    t += 0.5
                    continue
                }
                words += RecognizedWord(if (token in misheard) "mumble" else token, t, t + 0.5)
                t += 0.5
            }
            t += 1.0 // breath between paragraphs
        }
        return words
    }

    private fun paragraphs(texts: List<String>) = texts.mapIndexed { i, text -> Transcript.Paragraph(i, text, isEmphasis = false) }

    private fun nfd(vararg words: String) = words.map { Normalizer.normalize(it, Normalizer.Form.NFD) }

    private val sample = listOf(
        "You have come to an even more dangerous person than Nan-in, because an empty cup will not do; the cup has to be broken completely.",
        "The story is beautiful. It was bound to happen to a professor of philosophy. He must have come for the wrong reasons.",
        "When you argue, you assert. Assertion is violence, aggression, and the truth cannot be known by an aggressive mind.",
        "Ideas create stupidity because the more the ideas are there, the more the mind is burdened. And how can a burdened mind know?",
        "A religious mind is a nonphilosophical mind. A religious mind is an innocent, intelligent mind. The mirror is clear.",
        "This professor came to Nan-in. Those people who are filled with questions cannot receive anything; their cup is already full.",
    )

    private fun expectedStarts(ps: List<Transcript.Paragraph>): List<Double> {
        var expected = 0.0
        return ps.map { p -> expected.also { expected += p.text.split(' ').size * 0.5 + 1.0 } }
    }

    @Test
    fun normalisationStripsPunctuationCaseAndDiacritics() {
        assertThat(TranscriptAligner.normalizedTokens("Nan-in said: \"Wait!\" -- don't argue, café."))
            .containsExactly("nan", "in", "said", "wait", "dont", "argue", "cafe").inOrder()
        assertThat(TranscriptAligner.normalizedTokens("BELOVED MASTER,")).containsExactly("beloved", "master").inOrder()
        assertThat(TranscriptAligner.normalizedTokens("Naïve ÉLAN 1976")).containsExactly("naive", "elan", "1976").inOrder()
        assertThat(TranscriptAligner.normalizedTokens("  ,.;  ")).isEmpty()
    }

    @Test
    fun normalisationKeepsDevanagariWithItsMarks() {
        // Danda and hyphen split; matras, virama and nukta stay, because dropping them would merge
        // distinct words (कि / की, क / क्). Tokens are NFD, so ज़ arrives as ज plus nukta.
        assertThat(TranscriptAligner.normalizedTokens("रामकृष्ण के जीवन में। बार-बार ज़रा"))
            .containsExactlyElementsIn(nfd("रामकृष्ण", "के", "जीवन", "में", "बार", "बार", "ज़रा")).inOrder()
        assertThat(TranscriptAligner.normalizedTokens("कि की क क्")).containsExactly("कि", "की", "क", "क्").inOrder()
        assertThat(TranscriptAligner.normalizedTokens("‘मैं बोध-रूप हूं’ १०८")).containsExactly("मैं", "बोध", "रूप", "हूं", "१०८").inOrder()
        // Precomposed and decomposed nukta spellings normalise to the same token.
        assertThat(TranscriptAligner.normalizedTokens("\u095B")).isEqualTo(TranscriptAligner.normalizedTokens("\u091C\u093C"))
    }

    @Test
    fun hindiParagraphsAlignLikeEnglishOnes() {
        val ps = paragraphs(
            listOf(
                "रामकृष्ण के जीवन में ऐसा उल्लेख है कि जीवन भर तो उन्होंने मां का ही ध्यान किया। काली की मूर्ति के सामने नाचते रहे।",
                "तोतापुरी ने कहा, यह भी कल्पना है। इसे भी छोड़ो। जब तक मूर्ति है तब तक मन है।",
                "अष्टावक्र कहते हैं, तू निर्दोष है, इसलिए तू भूलकर भी यह मत मानना कि तू बंधा हुआ है।",
                "एक मनोवैज्ञानिक हारवर्ड विश्वविद्यालय में प्रयोग कर रहा था। उसने विद्यार्थियों को सम्मोहित किया।",
            ),
        )
        val starts = TranscriptAligner.paragraphStarts(ps, speak(ps, misheard = setOf("काली", "छोड़ो।")))
        assertThat(starts.filterNotNull()).hasSize(ps.size)
        assertThat(starts.map { it ?: -1.0 }).isInOrder()
        expectedStarts(ps).forEachIndexed { i, expected -> assertThat(abs(starts[i]!! - expected)).isLessThan(1.5) }
    }

    @Test
    fun longestIncreasingChainDropsOutOfOrderMatches() {
        val marks = listOf(
            TranscriptAligner.Landmark(0, 0),
            TranscriptAligner.Landmark(5, 90), // coincidence far ahead
            TranscriptAligner.Landmark(10, 12),
            TranscriptAligner.Landmark(20, 25),
            TranscriptAligner.Landmark(30, 3), // coincidence far behind
            TranscriptAligner.Landmark(40, 44),
        )
        assertThat(TranscriptAligner.longestIncreasingChain(marks).map { it.transcriptToken }).containsExactly(0, 10, 20, 40).inOrder()
        assertThat(TranscriptAligner.longestIncreasingChain(emptyList())).isEmpty()
    }

    @Test
    fun repeatedTrigramsAreNotLandmarks() {
        val transcript = listOf("a", "b", "c", "x", "a", "b", "c", "d", "e", "f")
        val heard = listOf("a", "b", "c", "d", "e", "f")
        val marks = TranscriptAligner.landmarks(transcript, heard)
        // "a b c" occurs twice in the transcript; only later unique trigrams survive.
        assertThat(marks.map { it.transcriptToken }).containsExactly(5, 6, 7).inOrder()
        assertThat(marks.map { it.wordIndex }).containsExactly(1, 2, 3).inOrder()
    }

    @Test
    fun perfectRecognitionRecoversEveryParagraphStart() {
        val ps = paragraphs(sample)
        val starts = TranscriptAligner.paragraphStarts(ps, speak(ps))
        assertThat(starts).hasSize(ps.size)
        // Each paragraph starts where its first word was spoken, give or take the local-rate walk back.
        expectedStarts(ps).forEachIndexed { i, expected ->
            val start = checkNotNull(starts[i]) { "paragraph $i" }
            assertThat(abs(start - expected)).isLessThan(0.6)
        }
    }

    @Test
    fun noisyRecognitionStillLandsWithinAFewSeconds() {
        val ps = paragraphs(sample)
        val starts = TranscriptAligner.paragraphStarts(ps, speak(ps, dropEvery = 7, misheard = setOf("mind", "cup", "professor")))
        val matched = starts.filterNotNull()
        assertThat(matched.size).isAtLeast(4)
        expectedStarts(ps).forEachIndexed { i, expected ->
            starts[i]?.let { assertThat(abs(it - expected)).isLessThan(4.0) }
        }
        assertThat(matched).isInOrder()
    }

    @Test
    fun unrelatedAudioYieldsNothingRatherThanNonsense() {
        val ps = paragraphs(sample)
        val other = paragraphs(
            listOf(
                "Zen and Taoists have always laughed about Confucius and this is one of their subtle jokes so try to understand it well.",
                "The cataract at Luliang falls from a height of two hundred feet and its foam reaches fifteen miles away from the falls.",
            ),
        )
        val starts = TranscriptAligner.paragraphStarts(ps, speak(other))
        assertThat(starts).hasSize(ps.size)
        assertThat(starts.all { it == null }).isTrue()
        assertThat(TranscriptAligner.paragraphStarts(ps, emptyList()).all { it == null }).isTrue()
    }
}
