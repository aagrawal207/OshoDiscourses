package com.agraabhi.oshodiscourses.core.domain.transcript

import kotlinx.coroutines.flow.StateFlow

/**
 * Fetch and disk cache of transcripts (iOS `TranscriptService`). Text is fetched behind each
 * committed download, backfilled for existing downloads, cached in `transcripts/<id>.json`
 * excluded from backup, and deleted with the audio. Opening one not cached fetches on demand.
 */
interface TranscriptRepository {
    /** Discourses whose transcript is on disk. */
    val cachedIDs: StateFlow<Set<String>>

    /** Discourses with a fetch in flight. */
    val loadingIDs: StateFlow<Set<String>>

    fun availability(discourseID: String): TranscriptAvailability

    /** From memory, disk or the network, in that order. Throws [TranscriptException]. */
    suspend fun transcript(discourseID: String, allowsCellular: Boolean = true): Transcript

    /** Background fetch behind a download; failures are silent. */
    suspend fun prefetch(discourseID: String, allowsCellular: Boolean = true)

    suspend fun backfill(downloadedIDs: List<String>, allowsCellular: Boolean)

    suspend fun remove(discourseID: String)

    /** Builds the time map from shipped or device alignment, else the estimate, bent by anchors. */
    fun timing(transcript: Transcript, duration: Double, state: TranscriptDiscourseState): TranscriptTiming

    companion object {
        /** Below this a fetched page is treated as blank. */
        const val MINIMUM_WORDS: Int = 50
    }
}

/**
 * A transcript load failure (iOS `TranscriptFetcher.FetchError` plus transport errors).
 * Site answers are final; only [Network] offers "Try Again".
 */
sealed class TranscriptException(message: String, cause: Throwable? = null) : Exception(message, cause) {
    open val isRetryable: Boolean get() = false

    class BadStatus(val code: Int) : TranscriptException("oshoworld.com answered with status $code.")

    class NoDescription : TranscriptException("The page did not contain a transcript.")

    class Blank : TranscriptException("oshoworld.com has no text for this discourse yet.")

    /** Transport failure; [message] is the platform's description. */
    class Network(message: String, cause: Throwable? = null) : TranscriptException(message, cause) {
        override val isRetryable: Boolean get() = true
    }
}

/**
 * Per-discourse anchors, read position and alignment in `transcript_state.json`
 * (iOS `TranscriptStateService`). Anchors and read positions sync; alignments stay local.
 */
interface TranscriptStateRepository {
    val states: StateFlow<Map<String, TranscriptDiscourseState>>

    /** The state for a transcript of [paragraphCount] paragraphs; drops data for another split. */
    fun state(discourseID: String, paragraphCount: Int): TranscriptDiscourseState

    fun state(discourseID: String): TranscriptDiscourseState? = states.value[discourseID]

    /** Replaces nearby or contradicting anchors; keeps at most [ANCHORS_PER_DISCOURSE_LIMIT]. */
    suspend fun addAnchor(discourseID: String, paragraph: Int, time: Double, fraction: Double? = null, paragraphCount: Int)

    suspend fun clearAnchors(discourseID: String)

    suspend fun setReadPosition(discourseID: String, paragraph: Int, paragraphCount: Int)

    /** Records "following the audio" with a timestamp. */
    suspend fun clearReadPosition(discourseID: String)

    suspend fun setAlignment(discourseID: String, alignment: TranscriptAlignment, paragraphCount: Int)

    suspend fun clearAlignment(discourseID: String)

    /** Most recent [SYNCED_DISCOURSE_LIMIT] discourses, for the sync snapshot. */
    fun syncedStates(): Map<String, TranscriptSyncedState>

    /** Anchor union replayed oldest first; newest read position wins. True if changed. */
    suspend fun mergeSynced(incoming: Map<String, TranscriptSyncedState>): Boolean

    companion object {
        const val SYNCED_DISCOURSE_LIMIT: Int = 300
        const val ANCHORS_PER_DISCOURSE_LIMIT: Int = 40
    }
}
