package com.agraabhi.oshodiscourses.core.data.transcript

import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptAnchor

/**
 * Anchor-set rules from iOS `TranscriptSyncModel.inserting` and `merge`. The timing model and
 * the state repository must share them so every device keeps the same surviving anchors.
 */
object TranscriptAnchorRules {
    private const val MIDDLE: Double = 0.5

    /**
     * Adds [anchor], evicting anything it contradicts: an anchor at the same spot, an earlier
     * position pinned to a later time, or a later one pinned earlier. The newest is the truth.
     */
    fun inserting(anchor: TranscriptAnchor, anchors: List<TranscriptAnchor>): List<TranscriptAnchor> {
        val b = anchor.fraction ?: MIDDLE
        val kept = anchors.filter { existing ->
            when {
                existing.paragraph == anchor.paragraph -> {
                    // Two blocks of one paragraph may both be pinned, in order.
                    val a = existing.fraction ?: MIDDLE
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
        return (kept + anchor).sortedWith(compareBy<TranscriptAnchor> { it.paragraph }.thenBy { it.fraction ?: MIDDLE })
    }

    /**
     * Order-independent merge: the union replayed oldest first through [inserting], so devices
     * holding the same anchors keep the same survivors whatever order they arrived in.
     */
    fun merge(a: List<TranscriptAnchor>, b: List<TranscriptAnchor>): List<TranscriptAnchor> {
        val union = LinkedHashSet<TranscriptAnchor>(a.size + b.size).apply { addAll(a); addAll(b) }
        val ordered = union.sortedWith(
            compareBy<TranscriptAnchor> { it.createdAt }
                .thenBy { it.paragraph }
                .thenBy { it.time }
                .thenBy { it.fraction ?: MIDDLE },
        )
        return ordered.fold(emptyList()) { acc, anchor -> inserting(anchor, acc) }
    }
}
