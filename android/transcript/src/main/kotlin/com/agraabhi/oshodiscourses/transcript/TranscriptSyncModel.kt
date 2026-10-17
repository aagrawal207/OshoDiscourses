package com.agraabhi.oshodiscourses.transcript

import com.agraabhi.oshodiscourses.core.domain.transcript.TimingSource
import com.agraabhi.oshodiscourses.core.domain.transcript.Transcript
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptAnchor
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptTiming

/**
 * Maps playback time to a paragraph and back for text with no timestamps (iOS `TranscriptSyncModel`).
 * The baseline is a constant speaking rate: a paragraph's share of characters is its share of the
 * duration. Knots pin one text position to one time, and the map is linear between neighbours.
 */
class TranscriptSyncModel private constructor(
    override val duration: Double,
    /** Cumulative character offsets; `starts[i]` is where paragraph i begins, the last is the total. */
    val starts: List<Double>,
    interior: List<Knot>,
    override val source: TimingSource,
) : TranscriptTiming {
    data class Knot(
        /** Character offset from the start of the transcript. */
        val position: Double,
        /** Seconds. */
        val time: Double,
    )

    /** Strictly increasing in both position and time, framed by (0, 0) and (total, duration). */
    val knots: List<Knot> = frame(interior, starts.last(), duration)

    constructor(
        paragraphs: List<Transcript.Paragraph>,
        duration: Double,
        knots: List<Knot> = emptyList(),
        source: TimingSource = TimingSource.ESTIMATE,
    ) : this(duration.coerceAtLeast(0.0), cumulativeStarts(paragraphs), knots, source)

    override val paragraphCount: Int get() = maxOf(0, starts.size - 1)

    /** Same transcript and duration with different interior knots. */
    fun with(knots: List<Knot>, source: TimingSource = this.source): TranscriptSyncModel =
        TranscriptSyncModel(duration, starts, knots, source)

    /** The anchored point of the paragraph (its middle unless the anchor says otherwise) maps to the time. */
    fun knot(anchor: TranscriptAnchor): Knot? {
        if (anchor.paragraph < 0 || anchor.paragraph >= paragraphCount) return null
        return Knot(position(anchor.paragraph, anchor.fraction ?: 0.5), anchor.time)
    }

    /** Knot for an aligned paragraph start. */
    fun knot(paragraph: Int, startingAt: Double): Knot? {
        if (paragraph < 0 || paragraph >= paragraphCount) return null
        return Knot(starts[paragraph], startingAt)
    }

    /**
     * Aligned starts corrected by the listener's anchors. An anchor says the alignment is wrong there,
     * so aligned starts contradicting it are dropped and the map bends to the anchor.
     */
    fun knots(alignedStarts: List<Double?>, anchors: List<TranscriptAnchor>): List<Knot> {
        val anchorKnots = anchors.mapNotNull { knot(it) }
        val aligned = alignedStarts.mapIndexedNotNull { index, start ->
            start?.let { knot(index, it) }?.takeUnless { k ->
                anchorKnots.any { a -> (k.position < a.position && k.time >= a.time) || (k.position > a.position && k.time <= a.time) }
            }
        }
        return aligned + anchorKnots
    }

    /** Character position [fraction] (0..1) of the way through [paragraph]. */
    fun position(paragraph: Int, fraction: Double): Double {
        if (paragraphCount == 0) return 0.0
        val i = paragraph.coerceIn(0, paragraphCount - 1)
        return starts[i] + fraction.coerceIn(0.0, 1.0) * (starts[i + 1] - starts[i])
    }

    override fun time(paragraph: Int, fraction: Double): Double {
        if (paragraphCount <= 0) return 0.0
        return timeAtPosition(position(paragraph, fraction))
    }

    override fun fraction(atTime: Double, paragraph: Int): Double {
        if (paragraph < 0 || paragraph >= paragraphCount) return 0.0
        val span = starts[paragraph + 1] - starts[paragraph]
        if (span <= 0) return 0.0
        return ((positionAtTime(atTime) - starts[paragraph]) / span).coerceIn(0.0, 1.0)
    }

    override fun startTime(paragraph: Int): Double {
        if (paragraphCount <= 0) return 0.0
        return timeAtPosition(starts[paragraph.coerceIn(0, paragraphCount - 1)])
    }

    override fun paragraphAt(time: Double): Int {
        if (paragraphCount <= 0) return 0
        val position = positionAtTime(time)
        // Last paragraph whose start is at or before the position.
        var lo = 0
        var hi = paragraphCount - 1
        while (lo < hi) {
            val mid = (lo + hi + 1) / 2
            if (starts[mid] <= position) lo = mid else hi = mid - 1
        }
        return lo
    }

    fun timeAtPosition(position: Double): Double = interpolate(position, Knot::position, Knot::time)

    fun positionAtTime(time: Double): Double = interpolate(time, Knot::time, Knot::position)

    private inline fun interpolate(x: Double, from: (Knot) -> Double, to: (Knot) -> Double): Double {
        val first = knots.firstOrNull() ?: return 0.0
        val last = knots.last()
        if (x <= from(first)) return to(first)
        if (x >= from(last)) return to(last)
        for (i in 1 until knots.size) {
            val a = knots[i - 1]
            val b = knots[i]
            if (x > from(b)) continue
            val span = from(b) - from(a)
            if (span <= 0) return to(b)
            val t = (x - from(a)) / span
            return to(a) + t * (to(b) - to(a))
        }
        return to(last)
    }

    companion object {
        /** A one-line sutra is recited slowly with pauses, so it weighs at least this many characters. */
        const val MINIMUM_WEIGHT: Double = 50.0

        private fun cumulativeStarts(paragraphs: List<Transcript.Paragraph>): List<Double> {
            val starts = ArrayList<Double>(paragraphs.size + 1)
            starts += 0.0
            // Whitespace-free length, so a verse broken over short lines isn't weighed by its formatting.
            for (p in paragraphs) starts += starts.last() + maxOf(nonWhitespaceScalars(p.text).toDouble(), MINIMUM_WEIGHT)
            return starts
        }

        /** Unicode scalars outside the White_Space property, matching iOS `unicodeScalars` weighting. */
        fun nonWhitespaceScalars(text: String): Int = text.codePoints().filter { !isUnicodeWhitespace(it) }.count().toInt()

        private fun isUnicodeWhitespace(cp: Int): Boolean = cp in 0x09..0x0D || cp == 0x20 || cp == 0x85 || cp == 0xA0 ||
            cp == 0x1680 || cp in 0x2000..0x200A || cp == 0x2028 || cp == 0x2029 || cp == 0x202F || cp == 0x205F || cp == 0x3000

        /**
         * Sorts and clamps interior knots, then frames them with (0, 0) and (total, duration). Knots not
         * strictly increasing in both axes are dropped for the earlier one, keeping the map monotonic.
         */
        private fun frame(interior: List<Knot>, total: Double, duration: Double): List<Knot> {
            if (total <= 0 || duration <= 0) return listOf(Knot(0.0, 0.0), Knot(maxOf(total, 1.0), maxOf(duration, 0.0)))
            val result = mutableListOf(Knot(0.0, 0.0))
            for (k in interior.sortedBy { it.position }) {
                val position = k.position.coerceIn(0.0, total)
                val time = k.time.coerceIn(0.0, duration)
                val previous = result.last()
                if (position <= previous.position || time <= previous.time || position >= total || time >= duration) continue
                result += Knot(position, time)
            }
            result += Knot(total, duration)
            return result
        }
    }
}
