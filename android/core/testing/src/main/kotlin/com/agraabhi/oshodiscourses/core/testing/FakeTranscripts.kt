package com.agraabhi.oshodiscourses.core.testing

import com.agraabhi.oshodiscourses.core.domain.transcript.TimingSource
import com.agraabhi.oshodiscourses.core.domain.transcript.Transcript
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptAlignment
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptAnchor
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptAvailability
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptDiscourseState
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptException
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptReadPosition
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptRepository
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptStateRepository
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptSyncedState
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptTiming
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update

object SampleTranscripts {
    val birdOnTheWing1 = Transcript(
        discourseID = SampleCatalog.firstDiscourse.id,
        sourceID = "6878dc6679c7824a20c86a2e",
        fetchedAt = 1_760_000_000_000L,
        paragraphs = listOf(
            Transcript.Paragraph(0, "A monk asked Joshu, \"Has a dog Buddha-nature or not?\"", isEmphasis = true),
            Transcript.Paragraph(1, "This is one of the most famous koans. Listen to it carefully. The question is not about the dog at all.", isEmphasis = false),
            Transcript.Paragraph(2, "Joshu said, \"Mu.\" And that mu is neither yes nor no. It simply drops the question.", isEmphasis = false),
            Transcript.Paragraph(3, "Meditate over it. Don't think about it; let it sink into your being.", isEmphasis = false),
        ),
    )
}

/** Serves [transcripts] as if fetched; anything else in [availableIDs] fails with [failure]. */
class FakeTranscriptRepository(
    private val transcripts: Map<String, Transcript> = mapOf(SampleTranscripts.birdOnTheWing1.discourseID to SampleTranscripts.birdOnTheWing1),
    private val availableIDs: Set<String> = transcripts.keys,
    cached: Set<String> = emptySet(),
    var failure: TranscriptException? = null,
) : TranscriptRepository {
    override val cachedIDs = MutableStateFlow(cached)
    override val loadingIDs = MutableStateFlow<Set<String>>(emptySet())

    override fun availability(discourseID: String): TranscriptAvailability = when {
        discourseID in cachedIDs.value -> TranscriptAvailability.CACHED
        discourseID in availableIDs -> TranscriptAvailability.NOT_CACHED
        else -> TranscriptAvailability.UNAVAILABLE
    }

    override suspend fun transcript(discourseID: String, allowsCellular: Boolean): Transcript {
        failure?.let { throw it }
        val transcript = transcripts[discourseID] ?: throw TranscriptException.Blank()
        cachedIDs.update { it + discourseID }
        return transcript
    }

    override suspend fun prefetch(discourseID: String, allowsCellular: Boolean) {
        if (discourseID in transcripts) cachedIDs.update { it + discourseID }
    }

    override suspend fun backfill(downloadedIDs: List<String>, allowsCellular: Boolean) = downloadedIDs.forEach { prefetch(it, allowsCellular) }

    override suspend fun remove(discourseID: String) = cachedIDs.update { it - discourseID }

    override fun timing(transcript: Transcript, duration: Double, state: TranscriptDiscourseState): TranscriptTiming =
        EvenTiming(transcript.paragraphs.size, duration)
}

/** Every paragraph gets an equal share of the duration. */
class EvenTiming(override val paragraphCount: Int, override val duration: Double) : TranscriptTiming {
    override val source: TimingSource = TimingSource.ESTIMATE
    private val span: Double get() = if (paragraphCount == 0) 0.0 else duration / paragraphCount

    override fun startTime(paragraph: Int): Double = paragraph.coerceIn(0, maxOf(paragraphCount - 1, 0)) * span

    override fun paragraphAt(time: Double): Int =
        if (span <= 0) 0 else (time / span).toInt().coerceIn(0, maxOf(paragraphCount - 1, 0))

    override fun time(paragraph: Int, fraction: Double): Double = startTime(paragraph) + fraction.coerceIn(0.0, 1.0) * span

    override fun fraction(atTime: Double, paragraph: Int): Double =
        if (span <= 0) 0.0 else ((atTime - startTime(paragraph)) / span).coerceIn(0.0, 1.0)
}

class FakeTranscriptStateRepository(
    initial: Map<String, TranscriptDiscourseState> = emptyMap(),
    private val clock: FakeClock = FakeClock(),
) : TranscriptStateRepository {
    override val states = MutableStateFlow(initial)

    private fun edit(id: String, transform: TranscriptDiscourseState.() -> TranscriptDiscourseState) =
        states.update { it + (id to (it[id] ?: TranscriptDiscourseState()).transform()) }

    override fun state(discourseID: String, paragraphCount: Int): TranscriptDiscourseState {
        val s = states.value[discourseID] ?: return TranscriptDiscourseState(paragraphCount = paragraphCount)
        return if (s.paragraphCount != null && s.paragraphCount != paragraphCount) TranscriptDiscourseState(paragraphCount = paragraphCount) else s
    }

    override suspend fun addAnchor(discourseID: String, paragraph: Int, time: Double, fraction: Double?, paragraphCount: Int) = edit(discourseID) {
        val anchor = TranscriptAnchor(paragraph, time, clock.nowMillis, fraction)
        copy(anchors = (anchors.filterNot { it.paragraph == paragraph } + anchor).takeLast(TranscriptStateRepository.ANCHORS_PER_DISCOURSE_LIMIT), paragraphCount = paragraphCount)
    }

    override suspend fun clearAnchors(discourseID: String) = edit(discourseID) { copy(anchors = emptyList()) }

    override suspend fun setReadPosition(discourseID: String, paragraph: Int, paragraphCount: Int) = edit(discourseID) {
        copy(readPosition = TranscriptReadPosition(paragraph, clock.nowMillis), paragraphCount = paragraphCount)
    }

    override suspend fun clearReadPosition(discourseID: String) = edit(discourseID) { copy(readPosition = TranscriptReadPosition.following(clock.nowMillis)) }

    override suspend fun setAlignment(discourseID: String, alignment: TranscriptAlignment, paragraphCount: Int) = edit(discourseID) {
        copy(alignment = alignment, paragraphCount = paragraphCount)
    }

    override suspend fun clearAlignment(discourseID: String) = edit(discourseID) { copy(alignment = null) }

    override fun syncedStates(): Map<String, TranscriptSyncedState> = states.value
        .entries.sortedByDescending { it.value.lastActivity }
        .take(TranscriptStateRepository.SYNCED_DISCOURSE_LIMIT)
        .associate { (id, s) -> id to TranscriptSyncedState(s.anchors, s.readPosition, s.paragraphCount) }

    override suspend fun mergeSynced(incoming: Map<String, TranscriptSyncedState>): Boolean {
        val before = states.value
        for ((id, remote) in incoming) edit(id) {
            copy(
                anchors = (anchors + remote.anchors).distinct().sortedBy { it.createdAt },
                readPosition = listOfNotNull(readPosition, remote.readPosition).maxByOrNull { it.updatedAt },
                paragraphCount = paragraphCount ?: remote.paragraphCount,
            )
        }
        return states.value != before
    }
}
