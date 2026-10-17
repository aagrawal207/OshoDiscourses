package com.agraabhi.oshodiscourses.feature.transcript.text

/** A half-open UTF-16 range `[start, end)` into a paragraph's text. */
data class TextSpan(val start: Int, val end: Int) {
    val isEmpty: Boolean get() = end <= start
}

fun String.slice(span: TextSpan): String = substring(span.start, span.end)

/** Whitespace-free length in code points, the unit every text weight in the reader uses. */
fun textWeight(text: CharSequence, start: Int = 0, end: Int = text.length): Int {
    var count = 0
    var i = start
    while (i < end) {
        val cp = Character.codePointAt(text, i)
        if (!isWhitespaceCodePoint(cp)) count++
        i += Character.charCount(cp)
    }
    return count
}

private fun isWhitespaceCodePoint(cp: Int): Boolean = Character.isWhitespace(cp) || Character.isSpaceChar(cp)

/**
 * Splits a paragraph into sentences so the reader can mark the one being spoken
 * (iOS `TranscriptSentences`). Shown only with aligned timing, since timing inside a
 * paragraph is interpolated from character share.
 */
object TranscriptSentences {
    private val terminators = setOf('.', '!', '?', '।', '॥', '…')
    private val trailing = setOf('"', '\'', '’', '”', ')', ']', '»')

    fun ranges(text: String): List<TextSpan> {
        val result = mutableListOf<TextSpan>()
        var start = 0
        var i = 0
        fun close(end: Int) {
            if (start < end) result += TextSpan(start, end)
            i = end
            while (i < text.length && text[i].isWhitespace()) i++
            start = i
        }
        while (i < text.length) {
            if (text[i] == '\n') {
                close(i)
                continue
            }
            if (text[i] !in terminators) {
                i++
                continue
            }
            var j = i
            while (j < text.length && (text[j] in terminators || text[j] in trailing)) j++
            // "e.g." and "3.5" end nothing, nor does a stop before a lowercase word
            // (`asking "What is light?" it shows...` is one sentence).
            if (j < text.length && !text[j].isWhitespace()) {
                i = j
                continue
            }
            var k = j
            while (k < text.length && text[k].isWhitespace() && text[k] != '\n') k++
            if (k < text.length && text[k].isLowerCase()) {
                i = k
                continue
            }
            close(j)
        }
        if (start < text.length) result += TextSpan(start, text.length)
        // A verse number or stray punctuation ("।। 18 ।।") belongs to the line before it.
        val merged = mutableListOf<TextSpan>()
        for (range in result) {
            val last = merged.lastOrNull()
            if (last != null && (range.start until range.end).none { text[it].isLetter() }) {
                merged[merged.lastIndex] = TextSpan(last.start, range.end)
            } else {
                merged += range
            }
        }
        return merged
    }

    /** The sentence being spoken once [fraction] of the paragraph has elapsed, letters spoken evenly. */
    fun index(fraction: Double, text: String): Int {
        val ranges = ranges(text)
        if (ranges.size <= 1) return 0
        val weights = ranges.map { textWeight(text, it.start, it.end).toDouble() }
        val total = weights.sum()
        if (total <= 0) return 0
        val target = fraction.coerceIn(0.0, 1.0) * total
        var accumulated = 0.0
        for ((i, w) in weights.withIndex()) {
            accumulated += w
            if (target < accumulated) return i
        }
        return ranges.lastIndex
    }
}

/**
 * Display rows cut from a paragraph at sentence boundaries (iOS `TranscriptBlocks`). Rows
 * are presentation only: anchors, alignment and read positions stay keyed by paragraph.
 */
object TranscriptBlocks {
    /** Letters a block aims for: four or five lines at the default size. */
    const val TARGET_LENGTH = 240

    /** Paragraphs up to this long stay whole in the block layout. */
    const val SPLIT_THRESHOLD = 360

    /** Sentences shorter than this ("Why?") join the sentence before them. */
    const val MINIMUM_SENTENCE_LENGTH = 40

    /** One row per sentence, with fragments folded into their predecessor. */
    fun sentenceRanges(text: String): List<TextSpan> {
        val result = mutableListOf<TextSpan>()
        for (range in TranscriptSentences.ranges(text)) {
            val last = result.lastOrNull()
            if (last != null && (weight(text, range) < MINIMUM_SENTENCE_LENGTH || weight(text, last) < MINIMUM_SENTENCE_LENGTH)) {
                result[result.lastIndex] = TextSpan(last.start, range.end)
            } else {
                result += range
            }
        }
        return result
    }

    /** Blocks of roughly [TARGET_LENGTH] letters for paragraphs over [SPLIT_THRESHOLD]. */
    fun ranges(text: String): List<TextSpan> {
        val sentences = TranscriptSentences.ranges(text)
        val weights = sentences.map { weight(text, it) }
        val total = weights.sum()
        if (sentences.size <= 1 || total <= SPLIT_THRESHOLD) {
            return if (text.isEmpty()) emptyList() else listOf(TextSpan(0, text.length))
        }
        // Equal blocks rather than full ones followed by a one-line remainder.
        val blockCount = maxOf(2, Math.round(total.toDouble() / TARGET_LENGTH).toInt())
        val ideal = total.toDouble() / blockCount
        val result = mutableListOf<TextSpan>()
        var blockStart = sentences[0].start
        var accumulated = 0
        for ((i, sentence) in sentences.withIndex()) {
            accumulated += weights[i]
            val isLast = i == sentences.lastIndex
            val blocksLeft = blockCount - result.size
            // Never leave more blocks to fill than sentences remain.
            if (!isLast && blocksLeft > 1 && accumulated >= ideal * 0.85 && sentences.size - i - 1 >= blocksLeft - 1) {
                result += TextSpan(blockStart, sentence.end)
                blockStart = sentences[i + 1].start
                accumulated = 0
            }
        }
        result += TextSpan(blockStart, text.length)
        return result
    }

    /** Character share (0..1, whitespace ignored) of each range's start and end, as the sync model weighs text. */
    fun fractions(ranges: List<TextSpan>, text: String): List<Pair<Double, Double>> {
        val weights = ranges.map { weight(text, it) }
        val total = weights.sum().toDouble()
        if (total <= 0) return ranges.map { 0.0 to 1.0 }
        var acc = 0.0
        return weights.map { w ->
            val start = acc / total
            acc += w
            start to acc / total
        }
    }

    private fun weight(text: String, span: TextSpan): Int = textWeight(text, span.start, span.end)
}
