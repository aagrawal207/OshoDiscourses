package com.agraabhi.oshodiscourses.transcript

import com.agraabhi.oshodiscourses.core.domain.transcript.Transcript
import java.text.Normalizer

/** A recognised word with its position in the audio, in seconds. */
data class RecognizedWord(val text: String, val start: Double, val end: Double)

/**
 * Aligns recogniser output to the transcript and reads off paragraph starts (iOS `TranscriptAligner`).
 * Word trigrams unique in both sequences are landmarks; the longest chain advancing through both
 * drops coincidences. Each paragraph starts at its first landmark, walked back at the local rate.
 */
object TranscriptAligner {
    /** Below this the recogniser most likely heard a different recording, or nothing. */
    const val MINIMUM_LANDMARKS: Int = 12

    /** Words a start may be extrapolated back across before interpolation is the better guess. */
    const val MAXIMUM_BACKWALK: Int = 40

    data class Landmark(val transcriptToken: Int, val wordIndex: Int)

    /** Seconds per paragraph, null where unmatched; all null when the audio is not this transcript. */
    fun paragraphStarts(paragraphs: List<Transcript.Paragraph>, words: List<RecognizedWord>): List<Double?> {
        val tokens = mutableListOf<String>()
        val tokenParagraph = mutableListOf<Int>()
        for (p in paragraphs) {
            for (token in normalizedTokens(p.text)) {
                tokens += token
                tokenParagraph += p.index
            }
        }
        val heard = words.map { normalizedTokens(it.text).joinToString("") }
        val landmarks = landmarks(tokens, heard)
        val starts = MutableList<Double?>(paragraphs.size) { null }
        if (landmarks.size < MINIMUM_LANDMARKS) return starts

        val firstToken = IntArray(paragraphs.size) { Int.MAX_VALUE }
        val lastToken = IntArray(paragraphs.size) { -1 }
        tokenParagraph.forEachIndexed { i, p ->
            firstToken[p] = minOf(firstToken[p], i)
            lastToken[p] = maxOf(lastToken[p], i)
        }

        var cursor = 0
        for (p in paragraphs.indices) {
            if (lastToken[p] < 0) continue
            while (cursor < landmarks.size && landmarks[cursor].transcriptToken < firstToken[p]) cursor++
            if (cursor >= landmarks.size || landmarks[cursor].transcriptToken > lastToken[p]) continue
            val mark = landmarks[cursor]
            val back = mark.transcriptToken - firstToken[p]
            if (back > MAXIMUM_BACKWALK) continue
            val rate = secondsPerToken(cursor, landmarks, words)
            starts[p] = maxOf(0.0, words[mark.wordIndex].start - back * rate)
        }
        return starts
    }

    /** Trigrams unique in both sequences, filtered to a monotonic chain. */
    fun landmarks(transcript: List<String>, heard: List<String>): List<Landmark> {
        val heardIndex = uniqueTrigrams(heard)
        val candidates = uniqueTrigrams(transcript)
            .mapNotNull { (key, t) -> heardIndex[key]?.let { Landmark(t, it) } }
            .sortedBy { it.transcriptToken }
        return longestIncreasingChain(candidates)
    }

    private fun uniqueTrigrams(seq: List<String>): Map<String, Int> {
        if (seq.size < 3) return emptyMap()
        val positions = HashMap<String, Int>()
        val repeated = HashSet<String>()
        for (i in 0..seq.size - 3) {
            val key = seq[i] + " " + seq[i + 1] + " " + seq[i + 2]
            if (key in positions) repeated += key else positions[key] = i
        }
        positions.keys.removeAll(repeated)
        return positions
    }

    /** Longest subsequence whose word indices strictly increase (transcript indices already do); patience sort. */
    fun longestIncreasingChain(marks: List<Landmark>): List<Landmark> {
        if (marks.isEmpty()) return emptyList()
        val tails = mutableListOf<Int>()
        val previous = IntArray(marks.size) { -1 }
        for ((i, m) in marks.withIndex()) {
            var lo = 0
            var hi = tails.size
            while (lo < hi) {
                val mid = (lo + hi) / 2
                if (marks[tails[mid]].wordIndex < m.wordIndex) lo = mid + 1 else hi = mid
            }
            if (lo > 0) previous[i] = tails[lo - 1]
            if (lo == tails.size) tails += i else tails[lo] = i
        }
        val chain = ArrayList<Landmark>()
        var i = tails.last()
        while (i >= 0) {
            chain += marks[i]
            i = previous[i]
        }
        return chain.asReversed()
    }

    private fun secondsPerToken(index: Int, landmarks: List<Landmark>, words: List<RecognizedWord>): Double {
        val a = landmarks[maxOf(0, index - 3)]
        val b = landmarks[minOf(landmarks.size - 1, index + 3)]
        val tokens = b.transcriptToken - a.transcriptToken
        val seconds = words[b.wordIndex].start - words[a.wordIndex].start
        // Osho speaks slowly: ~0.45 s a word is a sane default when the window collapses to one landmark.
        if (tokens <= 0 || seconds <= 0) return 0.45
        return (seconds / tokens).coerceIn(0.15, 1.5)
    }

    /**
     * Lowercased letters and digits of any script. Latin diacritics (U+0300–036F) drop, so "café" is
     * "cafe"; other combining marks stay, because Devanagari matras and virama distinguish words.
     */
    fun normalizedTokens(text: String): List<String> {
        val decomposed = Normalizer.normalize(text.lowercase(), Normalizer.Form.NFD)
        val tokens = mutableListOf<String>()
        val current = StringBuilder()
        // iOS splits on grapheme clusters judged by their first scalar; a mark joins the cluster before it.
        var clusterIsSeparator = true
        var previousWasControl = true
        var offset = 0
        while (offset < decomposed.length) {
            val cp = decomposed.codePointAt(offset)
            offset += Character.charCount(cp)
            val type = Character.getType(cp)
            val extendsCluster = !previousWasControl && (isMark(type) || cp == 0x200C || cp == 0x200D)
            if (!extendsCluster) clusterIsSeparator = !(Character.isAlphabetic(cp) || isNumeric(type) || cp == '\''.code)
            previousWasControl = type == Character.CONTROL.toInt()
            if (clusterIsSeparator) {
                if (current.isNotEmpty()) tokens += current.toString()
                current.clear()
            } else if (keepsInToken(cp, type)) {
                current.appendCodePoint(cp)
            }
        }
        if (current.isNotEmpty()) tokens += current.toString()
        return tokens
    }

    private fun keepsInToken(cp: Int, type: Int): Boolean {
        if (cp in 0x0300..0x036F) return false
        if (Character.isAlphabetic(cp) || isNumeric(type)) return true
        return type == Character.NON_SPACING_MARK.toInt() || type == Character.COMBINING_SPACING_MARK.toInt()
    }

    private fun isMark(type: Int): Boolean = type == Character.NON_SPACING_MARK.toInt() ||
        type == Character.COMBINING_SPACING_MARK.toInt() || type == Character.ENCLOSING_MARK.toInt()

    private fun isNumeric(type: Int): Boolean = type == Character.DECIMAL_DIGIT_NUMBER.toInt() ||
        type == Character.LETTER_NUMBER.toInt() || type == Character.OTHER_NUMBER.toInt()
}
