package com.agraabhi.oshodiscourses.playback

import android.content.Context
import android.net.Uri
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import com.agraabhi.oshodiscourses.core.domain.bookmarks.BookmarkRepository
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadManager
import com.agraabhi.oshodiscourses.core.domain.engagement.ReviewPrompter
import com.agraabhi.oshodiscourses.core.domain.player.AudioMixFailure
import com.agraabhi.oshodiscourses.core.domain.player.AudioProcessingStatus
import com.agraabhi.oshodiscourses.core.domain.player.PlayResult
import com.agraabhi.oshodiscourses.core.domain.player.PlaybackError
import com.agraabhi.oshodiscourses.core.domain.player.PlayerController
import com.agraabhi.oshodiscourses.core.domain.player.PlayerState
import com.agraabhi.oshodiscourses.core.domain.player.QueueItem
import com.agraabhi.oshodiscourses.core.domain.progress.PlaybackProgress
import com.agraabhi.oshodiscourses.core.domain.progress.PlaybackStateRepository
import com.agraabhi.oshodiscourses.core.domain.settings.SettingsRepository
import com.agraabhi.oshodiscourses.core.domain.settings.UserSettings
import com.agraabhi.oshodiscourses.core.domain.sleep.SleepTimer
import com.agraabhi.oshodiscourses.core.domain.sleep.SleepTimerMode
import com.agraabhi.oshodiscourses.core.domain.stats.ListeningStatsRepository
import com.agraabhi.oshodiscourses.core.model.BoostLevel
import com.agraabhi.oshodiscourses.core.model.CatalogRepository
import com.agraabhi.oshodiscourses.core.model.PlaybackSpeed
import com.agraabhi.oshodiscourses.denoise.DenoiseAudioPipeline
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.coroutines.ContinuationInterceptor
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * iOS `AudioPlayerService` + `PlaybackLauncher` over one ExoPlayer, whose playlist pauses after each
 * item so completion rules run here before advancing. State is main-thread only, like [scope].
 */
@OptIn(UnstableApi::class)
class PlaybackEngine(
    private val catalog: CatalogRepository,
    private val downloads: DownloadManager,
    private val bookmarks: BookmarkRepository,
    private val settings: SettingsRepository,
    private val playbackState: PlaybackStateRepository,
    private val listeningStats: ListeningStatsRepository,
    private val sleepTimer: SleepTimer,
    private val pipeline: DenoiseAudioPipeline,
    private val scope: CoroutineScope,
    private val playerFactory: () -> ExoPlayer,
    private val reviewPrompter: ReviewPrompter? = null,
    private val serviceBinding: PlaybackServiceBinding = PlaybackServiceBinding.None,
) : PlayerController {

    private val mainDispatcher: CoroutineDispatcher =
        scope.coroutineContext[ContinuationInterceptor] as? CoroutineDispatcher ?: Dispatchers.Main.immediate

    private val mutableState = MutableStateFlow(PlayerState())
    override val state: StateFlow<PlayerState> = mutableState.asStateFlow()

    private var exo: ExoPlayer? = null

    /** Created on first use; must be first touched on the main thread. */
    val player: ExoPlayer
        get() = exo ?: playerFactory().also { configure(it); exo = it }

    /** What the media session wraps; see [SessionPlayer]. */
    val sessionPlayer: Player by lazy { SessionPlayer(player, this) }

    /** A loaded item waiting for readiness; [explicit] is a position that overrides the saved one. */
    private class PendingStart(val explicit: Double?)

    private var queue: List<QueueItem> = emptyList()
    private var currentIndex = 0
    private var current: QueueItem? = null
    private var currentTime = 0.0
    private var duration = 0.0
    private var rate = 1f
    private var volume = 1f
    private var previousPosition: Double? = null
    private var error: PlaybackError? = null
    private var wantsPlayback = false
    private var pending: PendingStart? = null
    private var hasBeenReady = false
    private var interrupted = false
    private var wasPlayingBeforeInterruption = false
    private var noiseReductionEnabled = false

    // Callbacks can outlive an item; finishing is allowed once per load.
    private var generation = 0L
    private var finishedGeneration = -1L
    private var didTriggerPreemptiveDownload = false
    private var didManuallySeekNearEnd = false

    private var lastWrittenRate: Double? = null
    private var lastWrittenVolume: Double? = null
    private var lastSavedPosition: Pair<String, Double>? = null
    private var lastSeenRepositoryPosition: Pair<String, Double>? = null

    // Listening-time continuity between auto-save ticks (iOS `PlaybackStateService`).
    private var lastRecordedTime = 0.0
    private var lastRecordedTrackId: String? = null
    private var lastRecordedGeneration: Long? = null
    private var wasPlayingAtLastTick = false

    private var autoSaveJob: Job? = null
    private var progressJob: Job? = null

    private val isPlaying: Boolean
        get() = current != null && wantsPlayback && pending == null && !interrupted

    internal val currentIndexNow: Int get() = currentIndex

    private val listener = object : Player.Listener {
        override fun onPlaybackStateChanged(playbackState: Int) {
            if (playbackState == Player.STATE_ENDED) handleItemEnd()
            checkReadiness()
            publish()
        }

        override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
            when (reason) {
                Player.PLAY_WHEN_READY_CHANGE_REASON_END_OF_MEDIA_ITEM -> handleItemEnd()
                // Every in-app and session request goes through this class; only system pauses remain.
                Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST -> Unit
                else -> if (!playWhenReady && wantsPlayback) {
                    Log.i(TAG, "outcome=system_pause reason=$reason")
                    pausePlayback()
                }
            }
        }

        override fun onPlaybackSuppressionReasonChanged(playbackSuppressionReason: Int) {
            handleSuppression(playbackSuppressionReason)
        }

        override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
            // Pause-at-end normally prevents this; an automatic advance still counts as a finish.
            if (reason == Player.MEDIA_ITEM_TRANSITION_REASON_AUTO && current != null) handleItemEnd()
        }

        override fun onPositionDiscontinuity(oldPosition: Player.PositionInfo, newPosition: Player.PositionInfo, reason: Int) {
            refreshPosition()
            publish()
        }

        override fun onPlayerError(error: PlaybackException) = handleError(error)
    }

    // region PlayerController

    override suspend fun play(discourseID: String, from: Double?): PlayResult = onMain {
        if (current?.id == discourseID) {
            from?.let(::seekWithHistoryNow)
            if (!isPlaying) resumePlayback()
            return@onMain PlayResult.Started
        }
        when (val result = seriesQueue(discourseID)) {
            is SeriesQueue.Failed -> result.failure
            is SeriesQueue.Ready -> {
                playQueueNow(result.items, result.start, from)
                PlayResult.Started
            }
        }
    }

    override suspend fun playBookmark(bookmarkID: String): PlayResult = onMain {
        val bookmark = bookmarks.bookmarks.value.firstOrNull { it.id == bookmarkID }
            ?: return@onMain PlayResult.Failure.UNKNOWN_BOOKMARK
        if (current?.id == bookmark.discourseID) {
            seekWithHistoryNow(bookmark.timestamp)
            if (!isPlaying) resumePlayback()
            return@onMain PlayResult.Started
        }
        when (val result = seriesQueue(bookmark.discourseID)) {
            is SeriesQueue.Failed -> result.failure
            is SeriesQueue.Ready -> {
                playQueueNow(result.items, result.start, bookmark.timestamp)
                PlayResult.Started
            }
        }
    }

    override suspend fun playQueue(items: List<QueueItem>, startIndex: Int, resumeAt: Double?) = onMain {
        playQueueNow(items, startIndex, resumeAt)
    }

    override suspend fun playQueueItem(index: Int) = onMain { playQueueItemNow(index) }

    override suspend fun pause() = onMain { pausePlayback() }

    override suspend fun resume() = onMain { resumePlayback() }

    override suspend fun togglePlayPause() = onMain { if (isPlaying) pausePlayback() else resumePlayback() }

    override suspend fun setPlaying(playing: Boolean) = onMain { setPlayingNow(playing) }

    override suspend fun seek(to: Double) = onMain { seekNow(to) }

    override suspend fun seekWithHistory(to: Double) = onMain { seekWithHistoryNow(to) }

    override suspend fun returnToPreviousPosition() = onMain {
        val previous = previousPosition ?: return@onMain
        refreshPosition()
        val here = currentTime
        seekNow(previous)
        previousPosition = here
        publish()
    }

    override suspend fun clearPositionHistory() = onMain {
        previousPosition = null
        publish()
    }

    override suspend fun skipForward(seconds: Double) = onMain { skipForwardNow(seconds) }

    override suspend fun skipBackward(seconds: Double) = onMain { skipBackwardNow(seconds) }

    override suspend fun skipToNext() = onMain { skipToNextNow() }

    override suspend fun skipToPrevious() = onMain { skipToPreviousNow() }

    override suspend fun setRate(rate: Float) = onMain { setRateNow(rate) }

    override suspend fun setVolume(gain: Float) = onMain {
        val clamped = gain.coerceIn(0f, BoostLevel.MAXIMUM_GAIN)
        volume = clamped
        // Attenuation below unity is the player's job; gain above it is the DeNoise boost.
        exo?.volume = min(clamped, 1f)
        lastWrittenVolume = clamped.toDouble()
        write { settings.setVolumeBoost(clamped.toDouble()) }
        publish()
    }

    override suspend fun stop() = onMain {
        if (current != null) saveCurrentPositionNow()
        wantsPlayback = false
        pending = null
        unloadTrack()
        currentTime = 0.0
        duration = 0.0
        Log.i(TAG, "outcome=stopped")
        publish()
    }

    // endregion

    /**
     * Loads the latest downloaded discourse paused at its saved position, without opening the file
     * until play. Call once progress and downloads have loaded; false when nothing was restored.
     */
    suspend fun restoreLastSession(): Boolean = onMain {
        if (current != null) return@onMain false
        val id = playbackState.state.value.recentlyPlayed.firstOrNull { downloads.localFileURI(it) != null }
            ?: return@onMain false
        val result = seriesQueue(id) as? SeriesQueue.Ready ?: return@onMain false
        loadItem(result.start, resumeAt = null, autoPlay = false, playlist = result.items)
        Log.i(TAG, "outcome=session_restored")
        true
    }

    /** Releases the player and stops background work; the engine is unusable afterwards. */
    fun release() {
        autoSaveJob?.cancel()
        progressJob?.cancel()
        serviceBinding.release()
        exo?.removeListener(listener)
        exo?.release()
        exo = null
    }

    // region Main-thread operations (also used by the media session)

    internal fun setPlayingNow(playing: Boolean) {
        if (playing) {
            if (!isPlaying) resumePlayback()
        } else if (isPlaying || wantsPlayback) {
            pausePlayback()
        }
    }

    internal fun seekNow(to: Double) {
        val item = current ?: return
        if (!to.isFinite()) return
        val target = max(0.0, to)
        if (pending != null) {
            // Readiness would seek to the restore position and undo a seek made while loading.
            pending = PendingStart(target)
            currentTime = target
            publish()
            return
        }
        currentTime = target
        player.seekTo((target * 1000).toLong())
        pipeline.onDiscontinuity()
        savePosition(item.id, target)
        publish()
    }

    internal fun seekWithHistoryNow(to: Double) {
        refreshPosition()
        if (PlaybackRules.isNearEndSeek(to, duration)) didManuallySeekNearEnd = true
        if (abs(currentTime - to) > PlayerController.HISTORY_THRESHOLD_SECONDS) previousPosition = currentTime
        seekNow(to)
    }

    internal fun skipForwardNow(seconds: Double) {
        if (current == null) return
        // An unready item has no trustworthy duration, and finishing it would mark it complete.
        val knownDuration = if (pending == null) duration else 0.0
        when (val outcome = PlaybackRules.skipForwardOutcome(skipAnchor(), seconds, knownDuration)) {
            SkipOutcome.Finish -> finishCurrentTrack(naturally = false)
            is SkipOutcome.Seek -> seekNow(outcome.target)
        }
    }

    internal fun skipBackwardNow(seconds: Double) {
        if (current == null) return
        seekNow(PlaybackRules.skipBackwardTarget(skipAnchor(), seconds))
    }

    internal fun skipToNextNow() {
        if (current == null || currentIndex >= queue.size - 1) return
        loadItem(currentIndex + 1, resumeAt = null)
    }

    internal fun skipToPreviousNow() {
        if (current == null) return
        refreshPosition()
        if (currentTime > PlayerController.RESTART_THRESHOLD_SECONDS || currentIndex == 0) {
            seekNow(0.0)
            return
        }
        loadItem(currentIndex - 1, resumeAt = null)
    }

    internal fun playQueueItemNow(index: Int) {
        if (index !in queue.indices || index == currentIndex) return
        loadItem(index, resumeAt = null)
    }

    internal fun setRateNow(newRate: Float) {
        rate = PlaybackSpeed.normalized(newRate)
        exo?.setPlaybackSpeed(rate)
        // The speed control is the single source of truth for the default, as on iOS.
        lastWrittenRate = rate.toDouble()
        write { settings.setDefaultPlaybackRate(rate.toDouble()) }
        publish()
    }

    // endregion

    // region Loading

    private sealed interface SeriesQueue {
        data class Ready(val items: List<QueueItem>, val start: Int) : SeriesQueue

        data class Failed(val failure: PlayResult.Failure) : SeriesQueue
    }

    /** The series' downloaded discourses in catalog order, so auto-play continues through the series. */
    private fun seriesQueue(discourseID: String): SeriesQueue {
        val entry = catalog.entry(discourseID) ?: return SeriesQueue.Failed(PlayResult.Failure.UNKNOWN_DISCOURSE)
        if (downloads.localFileURI(discourseID) == null) return SeriesQueue.Failed(PlayResult.Failure.NOT_DOWNLOADED)
        val items = catalog.discourses(entry.series).mapNotNull { discourse ->
            downloads.localFileURI(discourse.id)?.let { QueueItem(discourse.id, it, discourse.displayTitle, entry.series.name) }
        }
        val start = items.indexOfFirst { it.id == discourseID }
        if (start < 0) return SeriesQueue.Failed(PlayResult.Failure.NOT_DOWNLOADED)
        return SeriesQueue.Ready(items, start)
    }

    private fun playQueueNow(items: List<QueueItem>, startIndex: Int, resumeAt: Double?) {
        if (items.isEmpty()) return
        loadItem(startIndex.coerceIn(0, items.lastIndex), resumeAt, playlist = items)
    }

    private fun loadItem(index: Int, resumeAt: Double?, autoPlay: Boolean = true, playlist: List<QueueItem>? = null) {
        // The outgoing position belongs to the loaded item, even when the caller replaces the queue.
        // A finished talk's position was cleared on completion and must not be written back.
        current?.takeIf { finishedGeneration != generation }?.let { outgoing ->
            refreshPosition()
            if (currentTime > 0) savePosition(outgoing.id, currentTime)
        }
        val items = playlist ?: queue
        val item = items[index]
        generation++
        queue = items
        currentIndex = index
        current = item
        // Shown until readiness picks the real start, so a restored talk displays its progress.
        currentTime = resumeAt ?: playbackState.getPosition(item.id)
        duration = playbackState.getDuration(item.id)
        pending = PendingStart(resumeAt)
        hasBeenReady = false
        wantsPlayback = autoPlay
        interrupted = false
        error = null
        previousPosition = null
        didTriggerPreemptiveDownload = false
        didManuallySeekNearEnd = false
        stopProgressUpdates()

        val player = player
        player.pause()
        if (playlist != null) player.setMediaItems(items.map(::mediaItem), index, 0) else player.seekTo(index, 0)
        if (autoPlay) {
            if (player.playbackState == Player.STATE_IDLE) player.prepare()
            serviceBinding.connect()
        }
        pipeline.onDiscontinuity()
        startAutoSave()
        Log.i(TAG, "outcome=item_loaded index=$index of=${items.size} autoPlay=$autoPlay")
        publish()
    }

    private fun checkReadiness() {
        val start = pending ?: return
        val item = current ?: return
        val player = exo ?: return
        if (player.playbackState != Player.STATE_READY || player.currentMediaItemIndex != currentIndex) return
        pending = null
        hasBeenReady = true
        duration = seconds(player.duration)
        val target = PlaybackRules.startPosition(start.explicit, playbackState.getPosition(item.id), duration)
        if (target != null) {
            player.seekTo((target * 1000).toLong())
            pipeline.onDiscontinuity()
            currentTime = target
        } else {
            currentTime = seconds(player.currentPosition)
        }
        Log.i(TAG, "outcome=item_ready restored=${target != null} explicit=${start.explicit != null}")
        if (wantsPlayback) {
            startPlayback()
            write { playbackState.recordPlay(item.id) }
        }
        publish()
    }

    private fun mediaItem(item: QueueItem): MediaItem {
        val artwork = catalog.entry(item.id)?.series?.id?.let(catalog::coverURL)
        val metadata = MediaMetadata.Builder()
            .setTitle(item.title)
            .setArtist(ARTIST)
            .setAlbumTitle(item.series)
            .setAlbumArtist(ARTIST)
            .setArtworkUri(artwork?.let(Uri::parse))
            .setIsPlayable(true)
            .setIsBrowsable(false)
            .build()
        return MediaItem.Builder().setMediaId(item.id).setUri(item.uri).setMediaMetadata(metadata).build()
    }

    private fun unloadTrack() {
        stopProgressUpdates()
        autoSaveJob?.cancel()
        autoSaveJob = null
        current = null
        queue = emptyList()
        currentIndex = 0
        pending = null
        previousPosition = null
        interrupted = false
        error = null
        exo?.let {
            it.pause()
            it.stop()
            it.clearMediaItems()
        }
        serviceBinding.release()
    }

    // endregion

    // region Transport

    private fun resumePlayback() {
        if (current == null || currentIndex !in queue.indices) return
        if (isPlaying) return
        wantsPlayback = true
        error = null
        serviceBinding.connect()
        val player = player
        if (player.playbackState == Player.STATE_IDLE) player.prepare()
        if (pending != null) {
            publish()
            checkReadiness()
            return
        }
        startPlayback()
        publish()
    }

    private fun startPlayback() {
        val player = player
        player.setPlaybackSpeed(rate)
        player.play()
        startProgressUpdates()
    }

    private fun pausePlayback() {
        wantsPlayback = false
        exo?.pause()
        stopProgressUpdates()
        // Autosave alone would lag by up to 10 s.
        saveCurrentPositionNow()
        publish()
    }

    private fun skipAnchor(): Double {
        pending?.let { return it.explicit ?: currentTime }
        return exo?.let { seconds(it.currentPosition) } ?: currentTime
    }

    // endregion

    // region Completion

    private fun handleItemEnd() {
        if (current == null || pending != null || finishedGeneration == generation) return
        finishCurrentTrack(naturally = !didManuallySeekNearEnd)
    }

    private fun finishCurrentTrack(naturally: Boolean) {
        val completed = current ?: return
        if (finishedGeneration == generation) return
        finishedGeneration = generation
        val preemptiveDownloadFired = didTriggerPreemptiveDownload
        exo?.pause()
        write {
            playbackState.markListenedComplete(completed.id)
            playbackState.clearPosition(completed.id)
        }
        val s = settings.settings.value
        // End-of-discourse sleep lets this talk finish, then stops instead of advancing.
        val endSleepArmed = sleepTimer.state.value.mode == SleepTimerMode.END_OF_DISCOURSE
        val autoNext = s.autoPlayNext && !endSleepArmed
        var playbackContinues = false
        Log.i(TAG, "outcome=finished natural=$naturally autoNext=$autoNext")

        if (autoNext) {
            // The finished talk's position was just cleared; zero keeps the next load from saving it back.
            currentTime = 0.0
        }
        val next = if (autoNext && currentIndex >= queue.size - 1) nextDownloadedItem(completed.id) else null
        when {
            autoNext && currentIndex < queue.size - 1 -> {
                playbackContinues = true
                loadItem(currentIndex + 1, resumeAt = null)
            }
            next != null -> {
                // Auto-play stays download-only: fall back to the next file on disk in series order.
                playbackContinues = true
                queue = queue + next
                player.addMediaItem(mediaItem(next))
                loadItem(queue.lastIndex, resumeAt = null)
            }
            else -> {
                wantsPlayback = false
                // Snap to the end only when it is known; 0 would misreport the finish.
                if (duration > 0) currentTime = duration
                unloadTrack()
                publish()
            }
        }

        performSmartDelete(completed.id)
        if (!preemptiveDownloadFired) performSmartDownload(completed.id)
        write { sleepTimer.discourseDidFinish() }
        reviewPrompter?.let { prompter ->
            write { prompter.discourseDidFinish(naturally, playbackContinues, endSleepArmed) }
        }
    }

    private fun performSmartDelete(discourseID: String) {
        if (!settings.settings.value.smartDelete) return
        if (discourseID !in downloads.downloadedIDs.value) return
        write { downloads.delete(discourseID) }
    }

    /**
     * Queues the next discourse in the series that is not on disk. The Wi-Fi-only rule is applied
     * by [DownloadManager], which holds the transfer until Wi-Fi when cellular is not allowed.
     */
    private fun performSmartDownload(afterDiscourseID: String) {
        if (!settings.settings.value.smartDownload) return
        val entry = catalog.entry(afterDiscourseID) ?: return
        val all = catalog.discourses(entry.series)
        val index = all.indexOfFirst { it.id == afterDiscourseID }
        if (index < 0) return
        val downloaded = downloads.downloadedIDs.value
        val next = all.drop(index + 1).firstOrNull { it.id !in downloaded } ?: return
        Log.i(TAG, "outcome=smart_download_queued")
        write { downloads.enqueue(next.id) }
    }

    private fun nextDownloadedItem(afterDiscourseID: String): QueueItem? {
        val entry = catalog.entry(afterDiscourseID) ?: return null
        val all = catalog.discourses(entry.series)
        val nextID = PlaybackRules.nextDownloadedId(afterDiscourseID, all.map { it.id }) { downloads.localFileURI(it) != null }
            ?: return null
        val discourse = all.first { it.id == nextID }
        val uri = downloads.localFileURI(nextID) ?: return null
        return QueueItem(discourse.id, uri, discourse.displayTitle, entry.series.name)
    }

    // endregion

    // region System events

    private fun handleSuppression(reason: Int) {
        if (reason == Player.PLAYBACK_SUPPRESSION_REASON_TRANSIENT_AUDIO_FOCUS_LOSS) {
            if (interrupted) return
            wasPlayingBeforeInterruption = isPlaying
            interrupted = true
            stopProgressUpdates()
            saveCurrentPositionNow()
            Log.i(TAG, "outcome=interruption_began playing=$wasPlayingBeforeInterruption")
            publish()
        } else if (interrupted) {
            interrupted = false
            // ExoPlayer resumes on regained focus only if it still wants to play, the system's resume grant.
            val resume = PlaybackRules.shouldResumeAfterInterruption(wasPlayingBeforeInterruption, exo?.playWhenReady == true)
            wasPlayingBeforeInterruption = false
            Log.i(TAG, "outcome=interruption_ended resume=$resume")
            if (resume) startProgressUpdates() else if (wantsPlayback) pausePlayback()
            publish()
        }
    }

    private fun handleError(e: PlaybackException) {
        if (current == null) return
        Log.w(TAG, "outcome=playback_failed code=${e.errorCodeName}")
        wantsPlayback = false
        exo?.pause()
        stopProgressUpdates()
        // An item that failed before its first frame has no position of its own; null lets the saved one win.
        val retryAt = pending?.explicit ?: if (hasBeenReady && currentTime > 0) currentTime else null
        pending = PendingStart(retryAt)
        error = PlaybackError(AudioProcessingStatus.SetupFailed(AudioMixFailure.PLAYBACK).detail)
        publish()
    }

    private fun onSettingsChanged(s: UserSettings) {
        noiseReductionEnabled = s.noiseReduction
        // Adopt values written elsewhere (or loaded late from disk), never echo our own writes.
        if (s.defaultPlaybackRate != lastWrittenRate) {
            val stored = PlaybackSpeed.normalized(s.defaultPlaybackRate.toFloat())
            if (!PlaybackSpeed.matches(stored, rate)) {
                rate = stored
                exo?.setPlaybackSpeed(rate)
            }
        }
        if (s.volumeBoost != lastWrittenVolume) {
            volume = s.volumeBoost.toFloat().coerceIn(1f, BoostLevel.MAXIMUM_GAIN)
            exo?.volume = min(volume, 1f)
        }
        publish()
    }

    /** Another device's progress moves a paused, loaded talk, or its next autosave would write the older position back. */
    private fun onProgressChanged(progress: PlaybackProgress) {
        val item = current ?: return
        val stored = progress.positions[item.id] ?: 0.0
        val seen = lastSeenRepositoryPosition
        lastSeenRepositoryPosition = item.id to stored
        if (seen == null || seen.first != item.id || seen.second == stored) return
        if (lastSavedPosition == item.id to stored || isPlaying || stored <= currentTime + 1) return
        if (pending != null) {
            if (pending?.explicit == null) currentTime = stored
        } else {
            exo?.seekTo((stored * 1000).toLong())
            pipeline.onDiscontinuity()
            currentTime = stored
        }
        publish()
    }

    // endregion

    // region Progress and auto-save

    private fun startProgressUpdates() {
        if (progressJob?.isActive == true) return
        progressJob = scope.launch {
            while (isActive) {
                delay(PlaybackRules.PROGRESS_INTERVAL_MS)
                onProgressTick()
            }
        }
    }

    private fun stopProgressUpdates() {
        progressJob?.cancel()
        progressJob = null
    }

    private fun onProgressTick() {
        if (!isPlaying) return
        refreshPosition()
        val item = current
        if (item != null && !didTriggerPreemptiveDownload && PlaybackRules.shouldTriggerSmartDownload(currentTime, duration)) {
            didTriggerPreemptiveDownload = true
            performSmartDownload(item.id)
        }
        publish()
    }

    private fun refreshPosition() {
        if (pending != null || current == null) return
        val player = exo ?: return
        currentTime = seconds(player.currentPosition)
    }

    private fun startAutoSave() {
        if (autoSaveJob?.isActive == true) return
        autoSaveJob = scope.launch {
            while (isActive) {
                delay(PlaybackRules.AUTO_SAVE_INTERVAL_MS)
                autoSaveTick()
            }
        }
    }

    /** iOS `PlaybackStateService.saveCurrentPosition`: save, then count continuous listening. */
    private fun autoSaveTick() {
        val item = current
        if (item == null || pending != null) {
            resetListeningContinuity()
            return
        }
        refreshPosition()
        val position = currentTime
        if (!position.isFinite() || position <= 0) {
            resetListeningContinuity()
            return
        }
        savePosition(item.id, position)
        // A listener can leave and return to the same recording between ticks.
        if (item.id != lastRecordedTrackId || generation != lastRecordedGeneration) {
            lastRecordedTrackId = item.id
            lastRecordedGeneration = generation
            lastRecordedTime = position
            wasPlayingAtLastTick = false
        }
        if (isPlaying) {
            val delta = position - lastRecordedTime
            if (wasPlayingAtLastTick && PlaybackRules.isContinuousListening(delta, rate)) {
                write { listeningStats.recordListeningTime(delta) }
            }
            lastRecordedTime = position
            wasPlayingAtLastTick = true
        } else {
            wasPlayingAtLastTick = false
        }
        write { listeningStats.save() }
        publish()
    }

    private fun resetListeningContinuity() {
        lastRecordedTime = 0.0
        lastRecordedTrackId = null
        lastRecordedGeneration = null
        wasPlayingAtLastTick = false
    }

    private fun saveCurrentPositionNow() {
        val item = current ?: return
        refreshPosition()
        if (currentTime.isFinite() && currentTime > 0) savePosition(item.id, currentTime)
    }

    private fun savePosition(id: String, position: Double) {
        if (!position.isFinite() || position <= 0) return
        lastSavedPosition = id to position
        val knownDuration = duration
        write { playbackState.savePosition(id, position, knownDuration) }
    }

    // endregion

    private fun publish() {
        val item = current
        val status = pipeline.status.value
        mutableState.value = PlayerState(
            currentTrackId = item?.id,
            currentTitle = item?.title.orEmpty(),
            currentSeries = item?.series.orEmpty(),
            isPlaying = isPlaying,
            isBuffering = item != null && wantsPlayback && (pending != null || exo?.playbackState == Player.STATE_BUFFERING),
            currentTime = currentTime,
            duration = duration,
            playbackRate = rate,
            volume = volume,
            queue = queue,
            currentIndex = currentIndex,
            previousPosition = previousPosition,
            error = error,
            audioProcessingStatus = status,
            isBoostAvailable = noiseReductionEnabled && status.isActive,
        )
    }

    private fun configure(player: ExoPlayer) {
        val attributes = AudioAttributes.Builder()
            .setUsage(C.USAGE_MEDIA)
            .setContentType(C.AUDIO_CONTENT_TYPE_SPEECH)
            .build()
        // ExoPlayer owns audio focus: a transient loss suppresses and resumes, a permanent one pauses.
        player.setAudioAttributes(attributes, true)
        player.setHandleAudioBecomingNoisy(true)
        player.setWakeMode(C.WAKE_MODE_LOCAL)
        player.pauseAtEndOfMediaItems = true
        player.setPlaybackSpeed(rate)
        player.volume = min(volume, 1f)
        player.addListener(listener)
    }

    /** Repository writes are fire-and-forget so the player logic stays synchronous on the main thread. */
    private fun write(block: suspend () -> Unit) {
        scope.launch {
            try {
                block()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "outcome=write_failed", e)
            }
        }
    }

    private suspend fun <T> onMain(block: () -> T): T = withContext(mainDispatcher) { block() }

    init {
        val initial = settings.settings.value
        // A stale or corrupt stored speed falls back onto the supported grid.
        rate = PlaybackSpeed.normalized(initial.defaultPlaybackRate.toFloat())
        volume = initial.volumeBoost.toFloat().coerceIn(1f, BoostLevel.MAXIMUM_GAIN)
        noiseReductionEnabled = initial.noiseReduction
        scope.launch { settings.settings.collect(::onSettingsChanged) }
        scope.launch { pipeline.status.collect { publish() } }
        scope.launch { playbackState.state.collect(::onProgressChanged) }
        publish()
    }

    companion object {
        private const val TAG = "Playback"
        private const val ARTIST = "Osho"

        private fun seconds(ms: Long): Double = if (ms == C.TIME_UNSET || ms < 0) 0.0 else ms / 1000.0

        /** The production engine: ExoPlayer with the DeNoise sink, bound to [PlaybackService]. */
        fun create(
            context: Context,
            catalog: CatalogRepository,
            downloads: DownloadManager,
            bookmarks: BookmarkRepository,
            settings: SettingsRepository,
            playbackState: PlaybackStateRepository,
            listeningStats: ListeningStatsRepository,
            sleepTimer: SleepTimer,
            pipeline: DenoiseAudioPipeline,
            reviewPrompter: ReviewPrompter? = null,
            scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
        ): PlaybackEngine {
            val app = context.applicationContext
            return PlaybackEngine(
                catalog = catalog,
                downloads = downloads,
                bookmarks = bookmarks,
                settings = settings,
                playbackState = playbackState,
                listeningStats = listeningStats,
                sleepTimer = sleepTimer,
                pipeline = pipeline,
                scope = scope,
                playerFactory = { buildPlayer(app, pipeline) },
                reviewPrompter = reviewPrompter,
                serviceBinding = MediaControllerServiceBinding(app),
            )
        }

        fun buildPlayer(context: Context, pipeline: DenoiseAudioPipeline): ExoPlayer =
            ExoPlayer.Builder(context, DenoiseRenderersFactory(context, pipeline))
                .setSeekBackIncrementMs((PlayerController.SKIP_BACKWARD_SECONDS * 1000).toLong())
                .setSeekForwardIncrementMs((PlayerController.SKIP_FORWARD_SECONDS * 1000).toLong())
                .build()
    }
}
