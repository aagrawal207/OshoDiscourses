package com.agraabhi.oshodiscourses.feature.player

import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.agraabhi.oshodiscourses.core.domain.AppServices
import com.agraabhi.oshodiscourses.core.domain.bookmarks.BookmarkCategory
import com.agraabhi.oshodiscourses.core.domain.bookmarks.BookmarkRepository
import com.agraabhi.oshodiscourses.core.domain.denoise.DenoiseController
import com.agraabhi.oshodiscourses.core.domain.denoise.DenoiseState
import com.agraabhi.oshodiscourses.core.domain.engagement.ReviewPrompter
import com.agraabhi.oshodiscourses.core.domain.player.PlayerController
import com.agraabhi.oshodiscourses.core.domain.player.PlayerState
import com.agraabhi.oshodiscourses.core.domain.sleep.SleepTimer
import com.agraabhi.oshodiscourses.core.domain.sleep.SleepTimerState
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptAvailability
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptRepository
import com.agraabhi.oshodiscourses.core.model.CatalogRepository
import com.agraabhi.oshodiscourses.core.model.PlaybackSpeed
import com.agraabhi.oshodiscourses.core.ui.LocalAppServices
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/** Everything the full player and mini-player draw, derived from the service contracts. */
@Immutable
data class PlayerUiState(
    val player: PlayerState,
    val sleep: SleepTimerState,
    val denoise: DenoiseState,
    /** Null when the catalog no longer has the playing discourse; the title is then not a link. */
    val seriesID: String? = null,
    /** "Discourse 1 · Mumbai, 1974". */
    val subtitle: String? = null,
    val hasTranscript: Boolean = false,
) {
    val title: String get() = PlayerFormatting.playerTitle(player.currentTitle, player.currentSeries)

    val progress: Float
        get() = if (player.duration > 0) (player.currentTime / player.duration).toFloat().coerceIn(0f, 1f) else 0f

    val canGoPrevious: Boolean
        get() = player.hasPrevious || player.currentTime > PlayerController.RESTART_THRESHOLD_SECONDS

    val isQueueBrowsable: Boolean get() = player.queue.size > 1

    val isSpeedActive: Boolean get() = !PlaybackSpeed.matches(player.playbackRate, 1f)

    /** The orange line under the controls: shown only while DeNoise is on and stuck. */
    val denoiseIssue: String? get() = if (denoise.isEnabled && denoise.status.isIssue) denoise.status.label else null
}

/** The bookmark moment, captured when the listener taps Bookmark rather than when they save. */
@Immutable
data class BookmarkDraft(
    val discourseID: String,
    val seriesName: String,
    val title: String,
    val timestamp: Double,
)

/**
 * The player's state holder over the contracts, so `:app` can swap the real services in
 * through `LocalAppServices` without touching the screens.
 */
class PlayerViewModel(
    private val player: PlayerController,
    private val sleepTimer: SleepTimer,
    private val bookmarks: BookmarkRepository,
    denoise: DenoiseController,
    private val catalog: CatalogRepository,
    private val transcripts: TranscriptRepository,
    private val reviewPrompter: ReviewPrompter? = null,
) : ViewModel() {
    constructor(services: AppServices) : this(
        player = services.player,
        sleepTimer = services.sleepTimer,
        bookmarks = services.bookmarks,
        denoise = services.denoise,
        catalog = services.catalog,
        transcripts = services.transcripts,
        reviewPrompter = services.reviewPrompter,
    )

    val state: StateFlow<PlayerUiState> =
        combine(player.state, sleepTimer.state, denoise.state, transcripts.cachedIDs) { p, s, d, _ -> derive(p, s, d) }
            .stateIn(viewModelScope, SharingStarted.Eagerly, derive(player.state.value, sleepTimer.state.value, denoise.state.value))

    private fun derive(player: PlayerState, sleep: SleepTimerState, denoise: DenoiseState): PlayerUiState {
        val id = player.currentTrackId
        val entry = id?.let(catalog::entry)
        return PlayerUiState(
            player = player,
            sleep = sleep,
            denoise = denoise,
            seriesID = entry?.series?.id,
            subtitle = entry?.let { catalog.discourseSubtitle(it.discourse.number, it.series.name) },
            hasTranscript = id != null && transcripts.availability(id) != TranscriptAvailability.UNAVAILABLE,
        )
    }

    fun togglePlayPause() = launch {
        val wasPlaying = player.state.value.isPlaying
        player.togglePlayPause()
        // iOS asks for a review only after an on-screen pause, never after a resume.
        if (wasPlaying) reviewPrompter?.listenerDidPause()
    }

    fun skipBackward() = launch { player.skipBackward() }

    fun skipForward() = launch { player.skipForward() }

    fun skipToPrevious() = launch { player.skipToPrevious() }

    fun skipToNext() = launch { player.skipToNext() }

    /** A released scrub records history, so a long jump offers "Back to m:ss". */
    fun seekWithHistory(to: Double) = launch { player.seekWithHistory(to) }

    fun returnToPreviousPosition() = launch { player.returnToPreviousPosition() }

    fun setRate(rate: Float) {
        val normalized = PlaybackSpeed.normalized(rate)
        if (PlaybackSpeed.matches(normalized, player.state.value.playbackRate)) return
        launch { player.setRate(normalized) }
    }

    fun stepRate(steps: Int) = setRate(PlaybackSpeed.stepped(player.state.value.playbackRate, steps))

    fun startSleepTimer(minutes: Int) = launch { sleepTimer.start(minutes) }

    fun sleepAtEndOfDiscourse() = launch { sleepTimer.startUntilEndOfDiscourse() }

    fun cancelSleepTimer() = launch { sleepTimer.cancel() }

    fun playQueueItem(index: Int) = launch { player.playQueueItem(index) }

    /** Null with nothing loaded, so the Bookmark control cannot save a ghost moment. */
    fun bookmarkDraft(): BookmarkDraft? {
        val s = player.state.value
        val id = s.currentTrackId ?: return null
        return BookmarkDraft(id, s.currentSeries, s.currentTitle, s.currentTime)
    }

    fun saveBookmark(draft: BookmarkDraft, note: String, category: BookmarkCategory, customCategory: String) = launch {
        bookmarks.add(
            discourseID = draft.discourseID,
            seriesName = draft.seriesName,
            title = draft.title,
            timestamp = draft.timestamp,
            note = note,
            category = category,
            customCategory = if (category == BookmarkCategory.CUSTOM) customCategory else null,
        )
    }

    private fun launch(block: suspend () -> Unit) {
        viewModelScope.launch { block() }
    }
}

/** Keyed by the services instance so a swapped container never reuses a stale holder. */
@Composable
internal fun playerViewModel(): PlayerViewModel {
    val services = LocalAppServices.current
    return viewModel(key = "player-${System.identityHashCode(services)}") { PlayerViewModel(services) }
}
