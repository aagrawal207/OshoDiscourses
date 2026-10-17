package com.agraabhi.oshodiscourses.feature.transcript.text

import com.agraabhi.oshodiscourses.core.domain.transcript.Transcript
import kotlin.math.abs

/** A row's identity: its source paragraph and its position among that paragraph's rows. */
data class RowID(val paragraph: Int, val index: Int)

/**
 * One piece of a paragraph as shown on screen (iOS `TranscriptView.Block`). Sentence layout
 * gives one row per sentence; block layout keeps short paragraphs whole.
 */
data class TranscriptRow(
    val id: RowID,
    /** Position in reading order across the whole transcript. */
    val ordinal: Int,
    val text: String,
    /** Character share of the paragraph this row covers. */
    val start: Double,
    val end: Double,
    val isEmphasis: Boolean,
    val isLastInParagraph: Boolean,
    /** Space or line break that preceded this row in its paragraph. */
    val gapBefore: String = "",
) {
    val paragraph: Int get() = id.paragraph
    val isFirstInParagraph: Boolean get() = id.index == 0
    val midpoint: Double get() = (start + end) / 2

    /** A whole-paragraph row anchors without a fraction, the form older app versions read. */
    val isWholeParagraph: Boolean get() = start == 0.0 && end == 1.0
}

object TranscriptRows {
    fun build(transcript: Transcript, sentences: Boolean): List<TranscriptRow> {
        val result = mutableListOf<TranscriptRow>()
        for (paragraph in transcript.paragraphs) {
            val text = paragraph.text
            val ranges = if (sentences) TranscriptBlocks.sentenceRanges(text) else TranscriptBlocks.ranges(text)
            val shares = TranscriptBlocks.fractions(ranges, text)
            for ((i, range) in ranges.withIndex()) {
                result += TranscriptRow(
                    id = RowID(paragraph.index, i),
                    ordinal = result.size,
                    text = text.slice(range),
                    start = shares[i].first,
                    end = shares[i].second,
                    isEmphasis = paragraph.isEmphasis,
                    isLastInParagraph = i == ranges.lastIndex,
                    gapBefore = TranscriptPassages.gap(text, ranges.getOrNull(i - 1), range),
                )
            }
        }
        return result
    }

    /** The row being spoken: the last row of [paragraph] starting at or before [fraction]. */
    fun rowAt(rows: List<TranscriptRow>, paragraph: Int, fraction: Double): TranscriptRow? =
        rows.lastOrNull { it.paragraph == paragraph && it.start <= fraction } ?: rows.firstOrNull { it.paragraph == paragraph }

    /**
     * Sentence being spoken within [row], from how far through its paragraph the audio is.
     * Callers pass it only with aligned timing; an estimate can be minutes out.
     */
    fun sentenceIndex(row: TranscriptRow, paragraphFraction: Double): Int? {
        if (row.end <= row.start) return null
        return TranscriptSentences.index((paragraphFraction - row.start) / (row.end - row.start), row.text)
    }
}

/**
 * Text the reader copies or shares (iOS `TranscriptPassages`). Rows are a presentation split,
 * so passages rejoin the way the source reads.
 */
object TranscriptPassages {
    /** Rows in reading order; neighbours in one paragraph rejoin with their original spacing. */
    fun text(rows: List<TranscriptRow>): String {
        val result = StringBuilder()
        var previous: TranscriptRow? = null
        for (row in rows.sortedBy { it.ordinal }) {
            previous?.let {
                val continues = it.paragraph == row.paragraph && it.id.index + 1 == row.id.index
                result.append(if (continues) row.gapBefore else "\n\n")
            }
            result.append(row.text)
            previous = row
        }
        return result.toString()
    }

    fun shareText(text: String, series: String?, number: Int?): String {
        if (series == null || number == null) return text
        return "$text\n\n— Osho, $series #$number"
    }

    /** "Select Up to Here": adds every row between the picked row nearest [target] and [target]. */
    fun extending(selection: Set<RowID>, target: TranscriptRow, rows: List<TranscriptRow>): Set<RowID> {
        val nearest = rows.filter { it.id in selection }.map { it.ordinal }.minByOrNull { abs(it - target.ordinal) }
            ?: return selection + target.id
        val range = minOf(nearest, target.ordinal)..maxOf(nearest, target.ordinal)
        return selection + rows.filter { it.ordinal in range }.map { it.id }
    }

    /** Whitespace between two rows of a paragraph, reduced to one space or line break. */
    fun gap(text: String, previous: TextSpan?, next: TextSpan): String {
        if (previous == null || previous.end > next.start) return ""
        return if (text.substring(previous.end, next.start).contains('\n')) "\n" else " "
    }
}
