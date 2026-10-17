package com.agraabhi.oshodiscourses.core.data.transcript

import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptAnchor
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptSyncModel

/**
 * Anchor-set rules from iOS `TranscriptSyncModel.inserting` and `merge`, delegated to the timing
 * model so the reader and the state repository keep the same surviving anchors on every device.
 */
object TranscriptAnchorRules {
    fun inserting(anchor: TranscriptAnchor, anchors: List<TranscriptAnchor>): List<TranscriptAnchor> =
        TranscriptSyncModel.inserting(anchor, anchors)

    fun merge(a: List<TranscriptAnchor>, b: List<TranscriptAnchor>): List<TranscriptAnchor> = TranscriptSyncModel.merge(a, b)
}
