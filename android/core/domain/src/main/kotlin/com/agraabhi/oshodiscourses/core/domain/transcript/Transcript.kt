package com.agraabhi.oshodiscourses.core.domain.transcript

import kotlinx.serialization.Serializable

/** One discourse's transcript, split into the paragraphs the reader scrolls (iOS `Transcript`). */
@Serializable
data class Transcript(
    val discourseID: String,
    /** oshoworld audio id the text was fetched under. */
    val sourceID: String,
    /** Epoch milliseconds. */
    val fetchedAt: Long,
    val paragraphs: List<Paragraph>,
) {
    @Serializable
    data class Paragraph(
        /** Position in the transcript; anchors and read positions refer to it. */
        val index: Int,
        val text: String,
        /** Quoted material: the question being answered or the sutra being commented on. */
        val isEmphasis: Boolean,
    )

    val wordCount: Int get() = paragraphs.sumOf { p -> p.text.split(Regex("\\s+")).count { it.isNotEmpty() } }
}

/** A user correction: "the audio was at [time] while [paragraph] was spoken" (iOS `TranscriptAnchor`). */
@Serializable
data class TranscriptAnchor(
    val paragraph: Int,
    /** Seconds. */
    val time: Double,
    /** Epoch milliseconds. */
    val createdAt: Long,
    /** Position inside the paragraph (0..1 of its characters); null means the middle. */
    val fraction: Double? = null,
)

/**
 * Where the reader last was (iOS `TranscriptReadPosition`). A negative paragraph records
 * "following the audio again" with a timestamp so it beats an older position from another device.
 */
@Serializable
data class TranscriptReadPosition(
    val paragraph: Int,
    /** Epoch milliseconds. */
    val updatedAt: Long,
) {
    val isFollowing: Boolean get() = paragraph < 0

    companion object {
        fun following(at: Long): TranscriptReadPosition = TranscriptReadPosition(paragraph = -1, updatedAt = at)
    }
}

/** Device-local paragraph start times from speech alignment (iOS `TranscriptAlignment`). */
@Serializable
data class TranscriptAlignment(
    /** Seconds per paragraph; null where no confident match was found. */
    val starts: List<Double?>,
    /** Epoch milliseconds. */
    val createdAt: Long,
    /** Recogniser and locale that produced it. */
    val engine: String,
) {
    val matchedCount: Int get() = starts.count { it != null }
}

/** Everything remembered about one discourse's transcript, in `transcript_state.json`. */
@Serializable
data class TranscriptDiscourseState(
    val anchors: List<TranscriptAnchor> = emptyList(),
    val readPosition: TranscriptReadPosition? = null,
    val alignment: TranscriptAlignment? = null,
    /** Paragraph count the anchors refer to; a re-split transcript drops them. */
    val paragraphCount: Int? = null,
) {
    val lastActivity: Long get() = maxOf(readPosition?.updatedAt ?: Long.MIN_VALUE, anchors.maxOfOrNull { it.createdAt } ?: Long.MIN_VALUE)

    val isEmpty: Boolean get() = anchors.isEmpty() && readPosition == null && alignment == null
}

/** The synced slice of [TranscriptDiscourseState]; alignments stay on the device. */
@Serializable
data class TranscriptSyncedState(
    val anchors: List<TranscriptAnchor> = emptyList(),
    val readPosition: TranscriptReadPosition? = null,
    val paragraphCount: Int? = null,
) {
    val lastActivity: Long get() = maxOf(readPosition?.updatedAt ?: Long.MIN_VALUE, anchors.maxOfOrNull { it.createdAt } ?: Long.MIN_VALUE)
}

/** iOS `TranscriptService.Availability`. */
enum class TranscriptAvailability {
    /** oshoworld.com has no transcript for this discourse. */
    UNAVAILABLE,

    /** Exists on the site; not yet on this device. */
    NOT_CACHED,
    CACHED,
}

/** Where a [TranscriptTiming]'s paragraph starts come from, best first. */
enum class TimingSource {
    /** Shipped AlignmentCatalog.json entry matching paragraph count and duration (within 2.5 s). */
    SHIPPED_ALIGNMENT,

    /** On-device speech alignment. */
    DEVICE_ALIGNMENT,

    /** Share of characters equals share of duration, 50-character floor. */
    ESTIMATE,
}

/**
 * Maps playback time to a paragraph and back (iOS `TranscriptSyncModel`). User anchors bend
 * every source and win over aligned starts they contradict; the map is linear between knots.
 */
interface TranscriptTiming {
    val paragraphCount: Int
    val duration: Double
    val source: TimingSource

    /** Paragraphs with an aligned start, for "Synced from speech: m of n"; null for the estimate. */
    val matchedParagraphs: Int? get() = null

    fun startTime(paragraph: Int): Double

    fun paragraphAt(time: Double): Int

    /** Time at [fraction] (0..1 of characters) through [paragraph]. */
    fun time(paragraph: Int, fraction: Double): Double

    /** How far through [paragraph] (0..1) the audio is at [time]; drives the sentence highlight. */
    fun fraction(atTime: Double, paragraph: Int): Double
}
