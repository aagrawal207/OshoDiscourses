package com.agraabhi.oshodiscourses.feature.transcript

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.agraabhi.oshodiscourses.core.domain.player.PlayerController
import com.agraabhi.oshodiscourses.core.domain.player.PlayerState
import com.agraabhi.oshodiscourses.core.domain.settings.SettingsRepository
import com.agraabhi.oshodiscourses.core.domain.settings.UserSettings
import com.agraabhi.oshodiscourses.core.domain.transcript.TimingSource
import com.agraabhi.oshodiscourses.core.domain.transcript.Transcript
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptAvailability
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptDiscourseState
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptException
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptRepository
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptStateRepository
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptTiming
import com.agraabhi.oshodiscourses.core.model.CatalogRepository
import com.agraabhi.oshodiscourses.feature.transcript.text.RowID
import com.agraabhi.oshodiscourses.feature.transcript.text.TranscriptPassages
import com.agraabhi.oshodiscourses.feature.transcript.text.TranscriptRow
import com.agraabhi.oshodiscourses.feature.transcript.text.TranscriptRows
import com.agraabhi.oshodiscourses.feature.transcript.text.TranscriptSearch
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** What the reader body shows. */
sealed interface TranscriptContent {
    data object Loading : TranscriptContent

    /** oshoworld.com has no transcript for this discourse. */
    data object NotPublished : TranscriptContent

    /** [canRetry] is false for the site's own answers, which a retry would repeat. */
    data class Failed(val message: String, val canRetry: Boolean) : TranscriptContent

    data class Loaded(val transcript: Transcript) : TranscriptContent
}

/** Text opened in the Select Text screen. */
data class TextSelectionItem(val text: String, val shareText: String)

/** How a scroll to a row moves (ui-style.md §7). */
enum class ScrollMotion(val millis: Int) {
    JUMP(0),
    FOLLOW(450),
    RESUME(400),
    DEFAULT(350),
}

/** Puts row [ordinal] at the reading line, 35 % from the top. */
data class ScrollCommand(val ordinal: Int, val motion: ScrollMotion)

/** Platform work the screen performs for the view model. */
sealed interface TranscriptEffect {
    data class Copy(val text: String) : TranscriptEffect

    data class Share(val text: String) : TranscriptEffect
}

data class TranscriptUiState(
    val content: TranscriptContent = TranscriptContent.Loading,
    val rows: List<TranscriptRow> = emptyList(),
    val seriesName: String? = null,
    val discourseNumber: Int? = null,
    /** The player has this discourse loaded; playback controls and the highlight engage only then. */
    val isPlayingThis: Boolean = false,
    val isPlaying: Boolean = false,
    val currentTime: Double = 0.0,
    val duration: Double = 0.0,
    val currentRow: RowID? = null,
    /** Sentence inside [currentRow] being spoken; only with aligned timing. */
    val currentSentence: Int? = null,
    val isFollowing: Boolean = true,
    /** Row at the reading line, reported by the list. */
    val scrolledRow: RowID? = null,
    /** Row whose action chips are open. */
    val tappedRow: RowID? = null,
    val isSelecting: Boolean = false,
    val selection: Set<RowID> = emptySet(),
    val isSearching: Boolean = false,
    val searchQuery: String = "",
    val searchCursor: Int = 0,
    val searchMatches: List<RowID> = emptyList(),
    val toast: String? = null,
    val fontSize: Double = UserSettings.DEFAULT_TRANSCRIPT_FONT_SIZE,
    val sentenceLayout: Boolean = true,
    val timingSource: TimingSource? = null,
    /** Paragraphs the timing in use has an aligned start for; null for the estimate. */
    val timingMatched: Int? = null,
    /** Matched paragraphs of the device alignment in use, for the Timing note. */
    val deviceAlignment: Pair<Int, Int>? = null,
    val anchorCount: Int = 0,
    val textSelection: TextSelectionItem? = null,
) {
    val transcript: Transcript? get() = (content as? TranscriptContent.Loaded)?.transcript
    val isLoaded: Boolean get() = content is TranscriptContent.Loaded

    fun row(id: RowID?): TranscriptRow? = id?.let { target -> rows.firstOrNull { it.id == target } }

    val currentOrdinal: Int? get() = row(currentRow)?.ordinal

    /** Aligned timing makes paragraph bounds trustworthy enough to mark one sentence. */
    val alignmentInUse: Boolean get() = timingSource != null && timingSource != TimingSource.ESTIMATE

    val showsNowPlaying: Boolean get() = isPlayingThis && isLoaded && !isFollowing && !isSearching && !isSelecting

    /** The pill points down when the spoken row is below the reading line. */
    val nowPlayingIsBelow: Boolean get() = (currentOrdinal ?: 0) > (row(scrolledRow)?.ordinal ?: 0)

    val canShrinkText: Boolean get() = fontSize > UserSettings.TRANSCRIPT_FONT_SIZES.first()
    val canGrowText: Boolean get() = fontSize < UserSettings.TRANSCRIPT_FONT_SIZES.last()

    /** The Timing section's explanation; null when this discourse is not loaded in the player. */
    val timingNote: String?
        get() {
            if (!isPlayingThis) return null
            val counts = deviceAlignment
            val matched = timingMatched
            val total = transcript?.paragraphs?.size
            return when {
                timingSource == TimingSource.DEVICE_ALIGNMENT && counts != null -> "Synced from speech: ${counts.first} of ${counts.second} paragraphs"
                timingSource == null || timingSource == TimingSource.ESTIMATE ->
                    "Estimated from text length. Tap a paragraph and choose “Audio is here” to correct it."
                matched != null && total != null -> "Synced from speech: $matched of $total paragraphs"
                else -> "Synced from speech"
            }
        }

    val clearAnchorsLabel: String? get() = when (anchorCount) {
        0 -> null
        1 -> "Clear 1 sync anchor"
        else -> "Clear $anchorCount sync anchors"
    }

    val selectionCountLabel: String get() = if (selection.isEmpty()) "Tap passages" else "${selection.size} selected"

    /** `"<i>/<n>"`, `"0/0"` for a real query with no match, else null. */
    val searchCounter: String?
        get() = when {
            searchMatches.isNotEmpty() -> "${minOf(searchCursor + 1, searchMatches.size)}/${searchMatches.size}"
            searchQuery.length >= TranscriptSearch.MINIMUM_QUERY_LENGTH -> "0/0"
            else -> null
        }
}

/**
 * The transcript reader's state (iOS `TranscriptView` state and actions). [timing] defaults to
 * the repository, which picks shipped alignment, device alignment or the estimate.
 */
class TranscriptViewModel(
    val discourseID: String,
    private val catalog: CatalogRepository,
    private val transcripts: TranscriptRepository,
    private val transcriptState: TranscriptStateRepository,
    private val player: PlayerController,
    private val settings: SettingsRepository,
    private val timing: (Transcript, Double, TranscriptDiscourseState) -> TranscriptTiming = transcripts::timing,
) : ViewModel() {
    private val mutableState = MutableStateFlow(initialState())
    val state: StateFlow<TranscriptUiState> = mutableState.asStateFlow()

    private val scrollChannel = Channel<ScrollCommand>(Channel.CONFLATED)
    val scrollCommands: Flow<ScrollCommand> = scrollChannel.receiveAsFlow()

    private val effectChannel = Channel<TranscriptEffect>(Channel.BUFFERED)
    val effects: Flow<TranscriptEffect> = effectChannel.receiveAsFlow()

    private var model: TranscriptTiming? = null
    private var modelInputs: Any? = null
    private var playerState: PlayerState = player.state.value
    private var discourseState: TranscriptDiscourseState? = null
    private var savedReadParagraph: Int? = null
    private var speechSync: Boolean = settings.settings.value.transcriptSpeechSync
    private var loadJob: Job? = null
    private var toastJob: Job? = null

    init {
        viewModelScope.launch { player.state.collect(::onPlayer) }
        viewModelScope.launch { settings.settings.collect(::onSettings) }
        viewModelScope.launch { transcriptState.states.collect { onStates() } }
    }

    private fun initialState(): TranscriptUiState {
        val entry = catalog.entry(discourseID)
        val s = settings.settings.value
        return TranscriptUiState(
            seriesName = entry?.series?.name,
            discourseNumber = entry?.discourse?.number,
            fontSize = s.transcriptFontSize,
            sentenceLayout = s.transcriptSentenceLayout,
        )
    }

    // Loading

    /** Resets the reader and loads, as each iOS appearance does. */
    fun start() {
        loadJob?.cancel()
        loadJob = viewModelScope.launch { load() }
    }

    fun retry() = start()

    private suspend fun load() {
        model = null
        modelInputs = null
        discourseState = null
        mutableState.update {
            it.copy(
                content = TranscriptContent.Loading, rows = emptyList(), currentRow = null, currentSentence = null,
                tappedRow = null, isSelecting = false, selection = emptySet(), isSearching = false, searchQuery = "",
                searchMatches = emptyList(), searchCursor = 0, textSelection = null, timingSource = null,
            )
        }
        if (transcripts.availability(discourseID) == TranscriptAvailability.UNAVAILABLE) {
            mutableState.update { it.copy(content = TranscriptContent.NotPublished) }
            return
        }
        val loaded = try {
            transcripts.transcript(discourseID)
        } catch (e: CancellationException) {
            throw e
        } catch (e: TranscriptException) {
            mutableState.update { it.copy(content = TranscriptContent.Failed(e.message.orEmpty(), e.isRetryable)) }
            return
        } catch (e: Exception) {
            mutableState.update { it.copy(content = TranscriptContent.Failed(e.message ?: e.toString(), canRetry = true)) }
            return
        }
        val count = loaded.paragraphs.size
        val stored = transcriptState.state(discourseID, count)
        discourseState = stored
        val rows = TranscriptRows.build(loaded, mutableState.value.sentenceLayout)
        mutableState.update {
            it.copy(content = TranscriptContent.Loaded(loaded), rows = rows, anchorCount = stored.anchors.size, deviceAlignment = alignmentCounts(stored))
        }
        rebuildModel()
        // Land where the reader left off, or on the audio.
        val read = stored.readPosition
        if (read != null && !read.isFollowing && read.paragraph < count) {
            savedReadParagraph = read.paragraph
            mutableState.update { it.copy(isFollowing = false) }
            firstRow(read.paragraph)?.let { scroll(it.ordinal, ScrollMotion.JUMP) }
        } else {
            mutableState.update { it.copy(isFollowing = true) }
            val target = if (mutableState.value.isPlayingThis) mutableState.value.currentOrdinal else 0
            scroll(target ?: 0, ScrollMotion.JUMP)
        }
    }

    private fun firstRow(paragraph: Int): TranscriptRow? = mutableState.value.rows.firstOrNull { it.paragraph == paragraph }

    // Inputs

    private fun onPlayer(p: PlayerState) {
        val previous = playerState
        playerState = p
        val isThis = p.currentTrackId == discourseID
        mutableState.update {
            it.copy(isPlayingThis = isThis, isPlaying = isThis && p.isPlaying, currentTime = p.currentTime, duration = p.duration)
        }
        val trackChanged = previous.currentTrackId != p.currentTrackId
        if (trackChanged || previous.duration != p.duration) rebuildModel() else updateCurrentRow()
        val s = mutableState.value
        if (trackChanged && isThis && s.isFollowing) s.currentOrdinal?.let { scroll(it, ScrollMotion.DEFAULT) }
    }

    private fun onSettings(s: UserSettings) {
        val before = mutableState.value
        mutableState.update { it.copy(fontSize = s.transcriptFontSize, sentenceLayout = s.transcriptSentenceLayout) }
        val transcript = before.transcript ?: return
        if (speechSync != s.transcriptSpeechSync) {
            speechSync = s.transcriptSpeechSync
            rebuildModel()
        }
        if (before.sentenceLayout == s.transcriptSentenceLayout) return
        val paragraph = before.row(before.scrolledRow)?.paragraph
        val rows = TranscriptRows.build(transcript, s.transcriptSentenceLayout)
        mutableState.update {
            it.copy(rows = rows, tappedRow = null, isSelecting = false, selection = emptySet(), currentRow = null, currentSentence = null)
        }
        updateCurrentRow(scrollWhenFollowing = false)
        refreshSearch(jump = false)
        val now = mutableState.value
        val target = if (now.isFollowing) now.currentOrdinal else paragraph?.let { firstRow(it)?.ordinal }
        target?.let { scroll(it, ScrollMotion.JUMP) }
    }

    private fun onStates() {
        val transcript = mutableState.value.transcript ?: return
        val updated = transcriptState.state(discourseID, transcript.paragraphs.size)
        discourseState = updated
        mutableState.update { it.copy(anchorCount = updated.anchors.size, deviceAlignment = alignmentCounts(updated)) }
        rebuildModel()
    }

    private fun alignmentCounts(state: TranscriptDiscourseState): Pair<Int, Int>? =
        state.alignment?.let { it.matchedCount to it.starts.size }

    private fun rebuildModel() {
        val transcript = mutableState.value.transcript
        if (transcript == null || playerState.currentTrackId != discourseID) {
            model = null
            modelInputs = null
            mutableState.update { it.copy(currentRow = null, currentSentence = null, timingSource = null, timingMatched = null) }
            return
        }
        val stored = discourseState ?: transcriptState.state(discourseID, transcript.paragraphs.size)
        // A device alignment applies only while the listener has speech sync turned on (iOS).
        val stateNow = if (settings.settings.value.transcriptSpeechSync) stored else stored.copy(alignment = null)
        val inputs = listOf(transcript, playerState.duration, stateNow.anchors, stateNow.alignment)
        if (inputs != modelInputs || model == null) {
            model = timing(transcript, playerState.duration, stateNow)
            modelInputs = inputs
        }
        mutableState.update { it.copy(timingSource = model?.source, timingMatched = model?.matchedParagraphs) }
        updateCurrentRow()
    }

    private fun updateCurrentRow(scrollWhenFollowing: Boolean = true) {
        val model = model ?: return
        if (playerState.currentTrackId != discourseID) return
        val time = playerState.currentTime
        val paragraph = model.paragraphAt(time)
        val fraction = model.fraction(time, paragraph)
        val s = mutableState.value
        val row = TranscriptRows.rowAt(s.rows, paragraph, fraction)
        val sentence = if (row != null && s.alignmentInUse) TranscriptRows.sentenceIndex(row, fraction) else null
        val changed = row?.id != s.currentRow
        mutableState.update { it.copy(currentRow = row?.id, currentSentence = sentence) }
        if (changed && scrollWhenFollowing && mutableState.value.isFollowing && row != null) scroll(row.ordinal, ScrollMotion.FOLLOW)
    }

    private fun scroll(ordinal: Int, motion: ScrollMotion) {
        scrollChannel.trySend(ScrollCommand(ordinal, motion))
    }

    // Scrolling and following

    /** A drag past 24 dp or a fling hands control to the reader. */
    fun onUserScroll() {
        if (mutableState.value.isFollowing) mutableState.update { it.copy(isFollowing = false) }
    }

    /** Only a manual scroll moves the saved read position; following the audio needs none. */
    fun onScrolledRowChanged(id: RowID) {
        mutableState.update { it.copy(scrolledRow = id) }
        val s = mutableState.value
        val transcript = s.transcript ?: return
        if (s.isFollowing || savedReadParagraph == id.paragraph) return
        savedReadParagraph = id.paragraph
        viewModelScope.launch { transcriptState.setReadPosition(discourseID, id.paragraph, transcript.paragraphs.size) }
    }

    fun resumeFollowing() {
        mutableState.update { it.copy(isFollowing = true) }
        savedReadParagraph = null
        viewModelScope.launch { transcriptState.clearReadPosition(discourseID) }
        mutableState.value.currentOrdinal?.let { scroll(it, ScrollMotion.RESUME) }
    }

    // Rows

    fun onRowTap(row: TranscriptRow) {
        val s = mutableState.value
        if (s.isSelecting) {
            toggleSelection(row)
        } else {
            mutableState.update { it.copy(tappedRow = if (s.tappedRow == row.id) null else row.id) }
        }
    }

    fun onBackgroundTap() {
        if (mutableState.value.tappedRow != null) mutableState.update { it.copy(tappedRow = null) }
    }

    fun playFromHere(row: TranscriptRow) {
        val model = model ?: return
        val target = model.time(row.paragraph, row.start)
        viewModelScope.launch {
            player.seekWithHistory(target)
            if (!player.state.value.isPlaying) player.togglePlayPause()
        }
        resumeFollowing()
        mutableState.update { it.copy(tappedRow = null) }
    }

    /** Pins the row to the current playback time and follows from there. */
    fun anchorHere(row: TranscriptRow) {
        val transcript = mutableState.value.transcript ?: return
        val time = playerState.currentTime
        viewModelScope.launch {
            transcriptState.addAnchor(
                discourseID = discourseID,
                paragraph = row.paragraph,
                time = time,
                fraction = if (row.isWholeParagraph) null else row.midpoint,
                paragraphCount = transcript.paragraphs.size,
            )
        }
        mutableState.update { it.copy(tappedRow = null) }
        resumeFollowing()
        showToast(if (mutableState.value.sentenceLayout) "Synced to this sentence" else "Synced to this paragraph")
    }

    fun clearAnchors() {
        viewModelScope.launch { transcriptState.clearAnchors(discourseID) }
    }

    // Copy, share and selection

    private val selectedRows: List<TranscriptRow> get() = mutableState.value.let { s -> s.rows.filter { it.id in s.selection } }

    fun copy(rows: List<TranscriptRow>) {
        if (rows.isEmpty()) return
        effectChannel.trySend(TranscriptEffect.Copy(TranscriptPassages.text(rows)))
        showToast(if (rows.size == 1) "Copied" else "Copied ${rows.size} passages")
        mutableState.update { it.copy(tappedRow = null, isSelecting = false, selection = emptySet()) }
    }

    fun copySelection() = copy(selectedRows)

    fun share(rows: List<TranscriptRow>) {
        if (rows.isEmpty()) return
        effectChannel.trySend(TranscriptEffect.Share(shareText(TranscriptPassages.text(rows))))
    }

    fun shareSelection() = share(selectedRows)

    fun openTextSelection(rows: List<TranscriptRow>) {
        if (rows.isEmpty()) return
        val text = TranscriptPassages.text(rows)
        mutableState.update { it.copy(textSelection = TextSelectionItem(text, shareText(text))) }
    }

    fun openTextSelectionForSelection() = openTextSelection(selectedRows)

    fun closeTextSelection() = mutableState.update { it.copy(textSelection = null) }

    /** Picking passages while the page scrolls under the finger is impossible, so following stops. */
    fun startSelecting(row: TranscriptRow?) {
        mutableState.update {
            it.copy(tappedRow = null, isFollowing = false, isSelecting = true, selection = row?.let { r -> setOf(r.id) } ?: emptySet())
        }
    }

    fun stopSelecting() = mutableState.update { it.copy(isSelecting = false, selection = emptySet()) }

    fun toggleSelection(row: TranscriptRow) = mutableState.update {
        it.copy(selection = if (row.id in it.selection) it.selection - row.id else it.selection + row.id)
    }

    fun canSelectUpToHere(row: TranscriptRow): Boolean = mutableState.value.let { it.isSelecting && it.selection.isNotEmpty() && row.id !in it.selection }

    fun selectUpToHere(row: TranscriptRow) = mutableState.update {
        it.copy(selection = TranscriptPassages.extending(it.selection, row, it.rows))
    }

    fun canSelectWholeParagraph(row: TranscriptRow): Boolean {
        val s = mutableState.value
        val paragraphRows = s.rows.filter { it.paragraph == row.paragraph }
        return s.isSelecting && paragraphRows.size > 1 && !paragraphRows.all { it.id in s.selection }
    }

    fun selectWholeParagraph(row: TranscriptRow) = mutableState.update { s ->
        s.copy(selection = s.selection + s.rows.filter { it.paragraph == row.paragraph }.map { it.id })
    }

    private fun shareText(text: String): String {
        val s = mutableState.value
        return TranscriptPassages.shareText(text, s.seriesName, s.discourseNumber)
    }

    // Search

    fun toggleSearch() {
        if (mutableState.value.isSearching) cancelSearch() else mutableState.update { it.copy(isSearching = true) }
    }

    fun cancelSearch() = mutableState.update { it.copy(isSearching = false, searchQuery = "", searchMatches = emptyList(), searchCursor = 0) }

    /** Typing jumps to the first match and stops following. */
    fun setSearchQuery(query: String) {
        mutableState.update { it.copy(searchQuery = query) }
        refreshSearch(jump = true)
    }

    private fun refreshSearch(jump: Boolean) {
        val s = mutableState.value
        val query = TranscriptSearch.normalizedQuery(s.searchQuery)
        val matches = if (!s.isSearching || query == null) emptyList() else s.rows.filter { TranscriptSearch.contains(it.text, query) }.map { it.id }
        mutableState.update { it.copy(searchMatches = matches, searchCursor = 0) }
        val first = matches.firstOrNull()
        if (jump && first != null) {
            mutableState.update { it.copy(isFollowing = false) }
            mutableState.value.row(first)?.let { scroll(it.ordinal, ScrollMotion.DEFAULT) }
        }
    }

    fun jumpToMatch(offset: Int) {
        val s = mutableState.value
        val matches = s.searchMatches
        if (matches.isEmpty()) return
        val cursor = ((s.searchCursor + offset) % matches.size + matches.size) % matches.size
        mutableState.update { it.copy(searchCursor = cursor, isFollowing = false) }
        s.row(matches[cursor])?.let { scroll(it.ordinal, ScrollMotion.DEFAULT) }
    }

    // Options

    fun stepFontSize(direction: Int) {
        val sizes = UserSettings.TRANSCRIPT_FONT_SIZES
        val currentSize = mutableState.value.fontSize
        val current = sizes.indexOf(currentSize).takeIf { it >= 0 }
            ?: sizes.indices.minByOrNull { kotlin.math.abs(sizes[it] - currentSize) } ?: 2
        val next = (current + direction).coerceIn(0, sizes.lastIndex)
        viewModelScope.launch { settings.setTranscriptFontSize(sizes[next]) }
    }

    fun setSentenceLayout(enabled: Boolean) {
        viewModelScope.launch { settings.setTranscriptSentenceLayout(enabled) }
    }

    // Transport

    fun skipBackward() {
        viewModelScope.launch { player.skipBackward() }
    }

    fun skipForward() {
        viewModelScope.launch { player.skipForward() }
    }

    fun togglePlayPause() {
        viewModelScope.launch { player.togglePlayPause() }
    }

    // Toasts

    private fun showToast(text: String, millis: Long = 2_000) {
        toastJob?.cancel()
        mutableState.update { it.copy(toast = text) }
        toastJob = viewModelScope.launch {
            delay(millis)
            mutableState.update { if (it.toast == text) it.copy(toast = null) else it }
        }
    }
}
