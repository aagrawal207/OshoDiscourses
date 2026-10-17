package com.agraabhi.oshodiscourses.feature.transcript.text

import com.agraabhi.oshodiscourses.core.domain.transcript.TimingSource
import com.agraabhi.oshodiscourses.core.domain.transcript.Transcript
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptAnchor
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptTiming

/**
 * Maps playback time to a paragraph and back for a transcript with no timestamps
 * (iOS `TranscriptSyncModel`). A paragraph's share of the characters is its share of the
 * duration; knots pin one text position to one time and the map is linear between them.
 * Anchors become knots inside their paragraph, aligned starts become knots at paragraph starts.
 */
class TranscriptSyncModel private constructor(
    override val source: TimingSource,
    /** Cumulative character offsets; `starts[i]` is where paragraph i begins, the last is the total. */
    val starts: List<Double>,
    override val duration: Double,
    interior: List<Knot>,
) : TranscriptTiming {

    data class Knot(
        /** Character offset from the start of the transcript. */
        val position: Double,
        val time: Double,
    )

    constructor(
        paragraphs: List<Transcript.Paragraph>,
        duration: Double,
        knots: List<Knot> = emptyList(),
        source: TimingSource = TimingSource.ESTIMATE,
    ) : this(source, cumulativeStarts(paragraphs), maxOf(0.0, duration), knots)

    /** Strictly increasing in both axes, framed by (0, 0) and (total, duration). */
    val knots: List<Knot> = frame(interior, starts.last(), duration)

    override val paragraphCount: Int get() = maxOf(0, starts.size - 1)

    /** Knot for a user anchor: its point in the paragraph (the middle unless it says otherwise). */
    fun knot(anchor: TranscriptAnchor): Knot? {
        if (anchor.paragraph < 0 || anchor.paragraph >= paragraphCount) return null
        return Knot(position(anchor.paragraph, anchor.fraction ?: 0.5), anchor.time)
    }

    /** Knot for an aligned paragraph start. */
    fun knot(paragraph: Int, startingAt: Double): Knot? {
        if (paragraph < 0 || paragraph >= paragraphCount) return null
        return Knot(starts[paragraph], startingAt)
    }

    /** Character position [fraction] (0..1) of the way through [paragraph]. */
    fun position(paragraph: Int, fraction: Double): Double {
        if (paragraphCount == 0) return 0.0
        val i = paragraph.coerceIn(0, paragraphCount - 1)
        return starts[i] + fraction.coerceIn(0.0, 1.0) * (starts[i + 1] - starts[i])
    }

    /**
     * Aligned starts corrected by the listener's anchors. An anchor says the alignment is wrong
     * there, so aligned starts that contradict it are dropped and the map bends to the anchor.
     */
    fun knots(alignedStarts: List<Double?>, anchors: List<TranscriptAnchor>): List<Knot> {
        val anchorKnots = anchors.mapNotNull { knot(it) }
        val result = mutableListOf<Knot>()
        for ((index, start) in alignedStarts.withIndex()) {
            val k = start?.let { knot(index, it) } ?: continue
            val contradicted = anchorKnots.any { a ->
                (k.position < a.position && k.time >= a.time) || (k.position > a.position && k.time <= a.time)
            }
            if (!contradicted) result += k
        }
        return result + anchorKnots
    }

    /** Same transcript and duration with different knots. */
    fun with(knots: List<Knot>, source: TimingSource = this.source): TranscriptSyncModel =
        TranscriptSyncModel(source, starts, duration, knots)

    override fun startTime(paragraph: Int): Double {
        if (paragraphCount == 0) return 0.0
        return timeAtPosition(starts[paragraph.coerceIn(0, paragraphCount - 1)])
    }

    override fun paragraphAt(time: Double): Int {
        if (paragraphCount == 0) return 0
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

    override fun time(paragraph: Int, fraction: Double): Double {
        if (paragraphCount == 0) return 0.0
        return timeAtPosition(position(paragraph, fraction))
    }

    override fun fraction(atTime: Double, paragraph: Int): Double {
        if (paragraph < 0 || paragraph >= paragraphCount) return 0.0
        val span = starts[paragraph + 1] - starts[paragraph]
        if (span <= 0) return 0.0
        return ((positionAtTime(atTime) - starts[paragraph]) / span).coerceIn(0.0, 1.0)
    }

    fun timeAtPosition(position: Double): Double = interpolate(position, { it.position }, { it.time })

    fun positionAtTime(time: Double): Double = interpolate(time, { it.time }, { it.position })

    private inline fun interpolate(x: Double, from: (Knot) -> Double, to: (Knot) -> Double): Double {
        val first = knots.firstOrNull() ?: return 0.0
        val last = knots.last()
        if (x <= from(first)) return to(first)
        if (x >= from(last)) return to(last)
        // A framing pair plus a handful of anchors; a linear scan is enough.
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
        /**
         * Weight floor per paragraph: a one-line sutra is recited slowly with pauses around it,
         * so its few characters understate its share of the audio.
         */
        const val MINIMUM_WEIGHT: Double = 50.0

        /** The reader's map: [alignedStarts] corrected by [anchors] when present, else the estimate bent by them. */
        fun build(
            paragraphs: List<Transcript.Paragraph>,
            duration: Double,
            anchors: List<TranscriptAnchor>,
            alignedStarts: List<Double?>? = null,
            alignedSource: TimingSource = TimingSource.SHIPPED_ALIGNMENT,
        ): TranscriptSyncModel {
            val base = TranscriptSyncModel(paragraphs, duration)
            if (alignedStarts == null) return base.with(anchors.mapNotNull { base.knot(it) })
            return base.with(base.knots(alignedStarts, anchors), alignedSource)
        }

        private fun cumulativeStarts(paragraphs: List<Transcript.Paragraph>): List<Double> {
            val starts = ArrayList<Double>(paragraphs.size + 1)
            starts += 0.0
            for (p in paragraphs) {
                // Whitespace-free, so a verse broken over short lines is not weighted by its layout.
                starts += starts.last() + maxOf(textWeight(p.text).toDouble(), MINIMUM_WEIGHT)
            }
            return starts
        }

        /** Sorts, clamps and frames the knots, dropping any that would make the map non-monotonic. */
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

        /**
         * Adds [anchor], evicting what it contradicts: the same spot of its paragraph, an earlier
         * paragraph pinned later, or a later one pinned earlier. The newest anchor is the truth.
         */
        fun inserting(anchor: TranscriptAnchor, anchors: List<TranscriptAnchor>): List<TranscriptAnchor> {
            val kept = anchors.filter { existing ->
                when {
                    existing.paragraph == anchor.paragraph -> {
                        // Two rows of one paragraph may both be pinned, in order.
                        val a = existing.fraction ?: 0.5
                        val b = anchor.fraction ?: 0.5
                        when {
                            a == b -> false
                            a < b -> existing.time < anchor.time
                            else -> existing.time > anchor.time
                        }
                    }
                    existing.paragraph < anchor.paragraph -> existing.time < anchor.time
                    else -> existing.time > anchor.time
                }
            }
            return (kept + anchor).sortedWith(compareBy({ it.paragraph }, { it.fraction ?: 0.5 }))
        }

        /** Order-independent sync merge: the union replayed oldest first through [inserting]. */
        fun merge(a: List<TranscriptAnchor>, b: List<TranscriptAnchor>): List<TranscriptAnchor> {
            val union = (a + b).distinct().sortedWith(compareBy({ it.createdAt }, { it.paragraph }, { it.time }))
            return union.fold(emptyList()) { acc, anchor -> inserting(anchor, acc) }
        }
    }
}
