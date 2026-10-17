package com.agraabhi.oshodiscourses.playback

import android.content.Context
import android.content.Intent
import android.media.AudioManager
import androidx.media3.common.Player
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.agraabhi.oshodiscourses.core.domain.bookmarks.Bookmark
import com.agraabhi.oshodiscourses.core.domain.player.AudioProcessingStatus
import com.agraabhi.oshodiscourses.core.domain.player.PlayResult
import com.agraabhi.oshodiscourses.core.domain.progress.PlaybackProgress
import com.agraabhi.oshodiscourses.core.domain.settings.UserSettings
import com.agraabhi.oshodiscourses.core.domain.sync.CloudSnapshot
import com.agraabhi.oshodiscourses.core.testing.FakeSleepTimer
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runTest
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(AndroidJUnit4::class)
@Config(sdk = [36])
class PlaybackEngineTest {
    private val context: Context = ApplicationProvider.getApplicationContext()

    private fun TestScope.fixture(
        downloaded: Set<String> = BIRD.toSet(),
        durations: Map<String, Double> = emptyMap(),
        settings: UserSettings = UserSettings(),
        progress: PlaybackProgress = PlaybackProgress(),
        bookmarks: List<Bookmark> = emptyList(),
        sleepTimer: FakeSleepTimer = FakeSleepTimer(),
        failing: Set<String> = emptySet(),
    ) = EngineFixture(backgroundScope, context, downloaded, durations, settings, progress, bookmarks, sleepTimer, failing)

    private fun test(body: suspend TestScope.() -> Unit) = runTest(UnconfinedTestDispatcher()) { body() }

    private suspend fun EngineFixture.startPlaying(id: String = BIRD[0]) {
        assertThat(engine.play(id)).isEqualTo(PlayResult.Started)
        runUntil { state.isPlaying }
    }

    // region Launching (iOS PlaybackLauncher)

    @Test
    fun unknownUndownloadedAndRemovedTargetsReportWhyTheyCannotPlay() = test {
        val f = fixture(downloaded = setOf(BIRD[0]))
        assertThat(f.engine.play("english-Nowhere-1")).isEqualTo(PlayResult.Failure.UNKNOWN_DISCOURSE)
        assertThat(f.engine.play(BIRD[1])).isEqualTo(PlayResult.Failure.NOT_DOWNLOADED)
        assertThat(f.engine.playBookmark("gone")).isEqualTo(PlayResult.Failure.UNKNOWN_BOOKMARK)
        assertThat(f.state.hasTrack).isFalse()
    }

    @Test
    fun playQueuesTheSeriesDownloadsInOrderAndRecordsThePlay() = test {
        val f = fixture(downloaded = setOf(BIRD[0], BIRD[2]))
        f.startPlaying(BIRD[2])
        assertThat(f.state.queue.map { it.id }).containsExactly(BIRD[0], BIRD[2]).inOrder()
        assertThat(f.state.currentIndex).isEqualTo(1)
        assertThat(f.state.currentTitle).isEqualTo("A Bird on the Wing - #3")
        assertThat(f.state.currentSeries).isEqualTo("A Bird on the Wing")
        assertThat(f.player.currentMediaItem?.mediaId).isEqualTo(BIRD[2])
        assertThat(f.player.currentMediaItem?.mediaMetadata?.artist).isEqualTo("Osho")
        assertThat(f.player.currentMediaItem?.mediaMetadata?.albumTitle).isEqualTo("A Bird on the Wing")
        assertThat(f.progress.state.value.recentlyPlayed.first()).isEqualTo(BIRD[2])
    }

    @Test
    fun playingTheCurrentDiscourseResumesInsteadOfReloading() = test {
        val f = fixture()
        f.startPlaying()
        f.engine.pause()
        val discontinuities = f.pipeline.discontinuities
        f.engine.play(BIRD[0])
        assertThat(f.state.isPlaying).isTrue()
        assertThat(f.pipeline.discontinuities).isEqualTo(discontinuities)
    }

    @Test
    fun resumesFromTheSavedPosition() = test {
        val f = fixture(progress = PlaybackProgress(positions = mapOf(BIRD[0] to 100.0)))
        f.startPlaying()
        assertThat(f.state.currentTime).isWithin(0.5).of(100.0)
        assertThat(f.playerSeconds).isAtLeast(100.0)
        assertThat(f.state.duration).isEqualTo(600.0)
    }

    @Test
    fun aSavedPositionAtTheVeryEndStartsOver() = test {
        val f = fixture(progress = PlaybackProgress(positions = mapOf(BIRD[0] to 597.0)))
        f.startPlaying()
        assertThat(f.state.currentTime).isLessThan(1.0)
    }

    @Test
    fun restoringTheVeryEndDoesNotFinishTheTalk() = test {
        val f = fixture(durations = mapOf(BIRD[0] to 30.0))
        f.engine.playQueue(listOf(f.item(BIRD[0])), resumeAt = 30.0)
        f.runUntil { f.state.isPlaying }
        assertThat(f.state.currentTime).isAtMost(29.5)
        assertThat(f.state.currentTrackId).isEqualTo(BIRD[0])
        assertThat(f.progress.isCompleted(BIRD[0])).isFalse()
    }

    @Test
    fun aSeekWhileLoadingWinsOverTheSavedPosition() = test {
        val f = fixture(progress = PlaybackProgress(positions = mapOf(BIRD[0] to 8.0)))
        f.engine.play(BIRD[0])
        f.engine.seekWithHistory(20.0)
        assertThat(f.state.currentTime).isEqualTo(20.0)
        f.runUntil { f.state.isPlaying }
        assertThat(f.state.currentTime).isWithin(0.5).of(20.0)
    }

    @Test
    fun playFromOverridesTheSavedPosition() = test {
        val f = fixture(progress = PlaybackProgress(positions = mapOf(BIRD[0] to 8.0)))
        f.engine.play(BIRD[0], from = 250.0)
        f.runUntil { f.state.isPlaying }
        assertThat(f.state.currentTime).isWithin(0.5).of(250.0)
    }

    @Test
    fun bookmarksSeekWithHistoryWhenCurrentAndStartTheirTalkOtherwise() = test {
        val bookmarks = listOf(
            Bookmark(id = "here", discourseID = BIRD[0], seriesName = "A Bird on the Wing", title = "#1", timestamp = 300.0, createdAt = 1),
            Bookmark(id = "there", discourseID = BIRD[1], seriesName = "A Bird on the Wing", title = "#2", timestamp = 120.0, createdAt = 2),
        )
        val f = fixture(bookmarks = bookmarks)
        f.startPlaying()
        assertThat(f.engine.playBookmark("here")).isEqualTo(PlayResult.Started)
        assertThat(f.state.currentTime).isEqualTo(300.0)
        assertThat(f.state.previousPosition).isNotNull()

        assertThat(f.engine.playBookmark("there")).isEqualTo(PlayResult.Started)
        f.runUntil { f.state.currentTrackId == BIRD[1] && f.state.isPlaying }
        assertThat(f.state.currentTime).isWithin(0.5).of(120.0)
    }

    @Test
    fun restoresTheLastDiscoursePausedAtItsSavedPosition() = test {
        val f = fixture(
            downloaded = setOf(BIRD[0], BIRD[1]),
            progress = PlaybackProgress(
                positions = mapOf(BIRD[1] to 120.0),
                durations = mapOf(BIRD[1] to 600.0),
                recentlyPlayed = listOf(BIRD[2], BIRD[1]),
            ),
        )
        assertThat(f.engine.restoreLastSession()).isTrue()
        assertThat(f.state.currentTrackId).isEqualTo(BIRD[1])
        assertThat(f.state.isPlaying).isFalse()
        assertThat(f.state.currentTime).isEqualTo(120.0)
        assertThat(f.state.duration).isEqualTo(600.0)
        assertThat(f.state.queue.map { it.id }).containsExactly(BIRD[0], BIRD[1]).inOrder()
        assertThat(f.player.playbackState).isEqualTo(Player.STATE_IDLE)
        assertThat(f.engine.restoreLastSession()).isFalse()

        f.engine.resume()
        f.runUntil { f.state.isPlaying }
        assertThat(f.state.currentTime).isWithin(0.5).of(120.0)
    }

    // endregion

    // region Transport

    @Test
    fun setPlayingIsIdempotentAndPauseSavesThePosition() = test {
        val f = fixture()
        f.engine.setPlaying(true)
        assertThat(f.state.hasTrack).isFalse()

        f.startPlaying()
        f.playUntil(20.0)
        f.engine.setPlaying(true)
        assertThat(f.state.isPlaying).isTrue()
        f.engine.setPlaying(false)
        assertThat(f.state.isPlaying).isFalse()
        assertThat(f.progress.getPosition(BIRD[0])).isWithin(0.5).of(20.0)
        f.engine.setPlaying(false)
        assertThat(f.state.isPlaying).isFalse()
        assertThat(f.player.playWhenReady).isFalse()
        f.engine.setPlaying(true)
        assertThat(f.state.isPlaying).isTrue()
        assertThat(f.player.playWhenReady).isTrue()
    }

    @Test
    fun seeksSaveAndOnlyLongJumpsRecordHistory() = test {
        val f = fixture()
        f.startPlaying()
        f.engine.seek(100.0)
        assertThat(f.progress.getPosition(BIRD[0])).isEqualTo(100.0)
        assertThat(f.state.previousPosition).isNull()

        f.engine.seekWithHistory(105.0)
        assertThat(f.state.previousPosition).isNull()

        f.engine.seekWithHistory(400.0)
        assertThat(f.state.previousPosition).isWithin(0.5).of(105.0)
        assertThat(f.playerSeconds).isWithin(0.5).of(400.0)

        f.engine.returnToPreviousPosition()
        assertThat(f.state.currentTime).isWithin(0.5).of(105.0)
        assertThat(f.state.previousPosition).isWithin(0.5).of(400.0)

        f.engine.clearPositionHistory()
        assertThat(f.state.hasPreviousPosition).isFalse()
    }

    @Test
    fun skipsMoveByFifteenAndThirtySecondsAndAccumulate() = test {
        val f = fixture()
        f.startPlaying()
        f.engine.seek(100.0)
        f.engine.skipForward()
        f.engine.skipForward()
        assertThat(f.playerSeconds).isWithin(0.5).of(160.0)
        f.engine.skipBackward()
        assertThat(f.playerSeconds).isWithin(0.5).of(145.0)
        f.engine.seek(5.0)
        f.engine.skipBackward()
        assertThat(f.playerSeconds).isWithin(0.1).of(0.0)
    }

    @Test
    fun previousRestartsPastThreeSecondsAndOtherwiseGoesBack() = test {
        val f = fixture()
        f.startPlaying(BIRD[1])
        f.engine.seek(10.0)
        f.engine.skipToPrevious()
        assertThat(f.state.currentTrackId).isEqualTo(BIRD[1])
        assertThat(f.playerSeconds).isWithin(0.5).of(0.0)

        f.engine.skipToPrevious()
        f.runUntil { f.state.currentTrackId == BIRD[0] && f.state.isPlaying }
        assertThat(f.state.currentIndex).isEqualTo(0)
        assertThat(f.progress.getPosition(BIRD[1])).isWithin(0.5).of(10.0)
    }

    @Test
    fun nextAndQueueJumpsLoadTheChosenTalk() = test {
        val f = fixture()
        f.startPlaying()
        f.engine.skipToNext()
        f.runUntil { f.state.currentTrackId == BIRD[1] && f.state.isPlaying }
        f.engine.playQueueItem(2)
        f.runUntil { f.state.currentTrackId == BIRD[2] && f.state.isPlaying }
        assertThat(f.state.hasNext).isFalse()
        f.engine.skipToNext()
        assertThat(f.state.currentTrackId).isEqualTo(BIRD[2])
        f.engine.playQueueItem(7)
        assertThat(f.state.currentTrackId).isEqualTo(BIRD[2])
    }

    @Test
    fun speedSnapsToTheGridPersistsAndAppliesToThePlayer() = test {
        val f = fixture(settings = UserSettings(defaultPlaybackRate = 1.7))
        assertThat(f.state.playbackRate).isEqualTo(1.7f)
        f.startPlaying()
        assertThat(f.player.playbackParameters.speed).isEqualTo(1.7f)

        f.engine.setRate(1.33f)
        assertThat(f.state.playbackRate).isEqualTo(1.35f)
        assertThat(f.settings.settings.value.defaultPlaybackRate).isEqualTo(1.35f.toDouble())
        assertThat(f.player.playbackParameters.speed).isEqualTo(1.35f)

        f.engine.setRate(9f)
        assertThat(f.state.playbackRate).isEqualTo(2f)

        f.settings.setDefaultPlaybackRate(0.8)
        assertThat(f.state.playbackRate).isEqualTo(0.8f)
        assertThat(f.player.playbackParameters.speed).isEqualTo(0.8f)
    }

    @Test
    fun aCorruptStoredSpeedFallsBackOntoTheGrid() = test {
        val f = fixture(settings = UserSettings(defaultPlaybackRate = 7.3))
        assertThat(f.state.playbackRate).isEqualTo(2f)
    }

    @Test
    fun volumeAboveUnityIsTheBoostAndIsPersisted() = test {
        val f = fixture(settings = UserSettings(volumeBoost = 3.0))
        assertThat(f.state.volume).isEqualTo(3f)
        f.startPlaying()
        assertThat(f.player.volume).isEqualTo(1f)
        f.engine.setVolume(0.5f)
        assertThat(f.player.volume).isEqualTo(0.5f)
        f.engine.setVolume(9f)
        assertThat(f.state.volume).isEqualTo(4f)
        assertThat(f.settings.settings.value.volumeBoost).isEqualTo(4.0)
    }

    @Test
    fun stopSavesAndUnloads() = test {
        val f = fixture()
        f.startPlaying()
        f.engine.seek(42.0)
        f.playUntil(50.0)
        f.engine.stop()
        assertThat(f.progress.getPosition(BIRD[0])).isWithin(0.5).of(50.0)
        assertThat(f.state.hasTrack).isFalse()
        assertThat(f.state.queue).isEmpty()
        assertThat(f.player.mediaItemCount).isEqualTo(0)
    }

    // endregion

    // region Auto-save and listening time

    @Test
    fun autoSaveEveryTenSecondsCountsOnlyContinuousListening() = test {
        val f = fixture()
        f.startPlaying()
        f.playUntil(20.0)
        advanceTimeBy(9_000)
        assertThat(f.progress.state.value.positions).doesNotContainKey(BIRD[0])

        advanceTimeBy(1_100)
        assertThat(f.progress.getPosition(BIRD[0])).isAtLeast(20.0)
        assertThat(f.stats.stats.value.totalToday).isEqualTo(0.0)

        f.playUntil(30.0)
        advanceTimeBy(10_000)
        assertThat(f.progress.getPosition(BIRD[0])).isAtLeast(30.0)
        assertThat(f.stats.stats.value.totalToday).isWithin(1.0).of(10.0)
        assertThat(f.stats.saves).isAtLeast(2)

        // A seek is not listening.
        val listened = f.stats.stats.value.totalToday
        f.engine.seek(500.0)
        advanceTimeBy(10_000)
        assertThat(f.stats.stats.value.totalToday).isEqualTo(listened)
    }

    @Test
    fun pausedTicksKeepThePositionButCountNoListening() = test {
        val f = fixture()
        f.startPlaying()
        f.playUntil(15.0)
        f.engine.pause()
        advanceTimeBy(30_000)
        assertThat(f.stats.stats.value.totalToday).isEqualTo(0.0)
        assertThat(f.progress.getPosition(BIRD[0])).isWithin(0.5).of(15.0)
    }

    @Test
    fun anotherDevicesProgressMovesAPausedLoadedTalk() = test {
        val f = fixture()
        f.startPlaying()
        f.engine.seek(5.0)
        f.engine.pause()
        f.progress.mergeCloudSnapshot(CloudSnapshot(positions = mapOf(BIRD[0] to 25.0)))
        assertThat(f.state.currentTime).isEqualTo(25.0)
        assertThat(f.playerSeconds).isWithin(0.5).of(25.0)
        advanceTimeBy(10_001)
        assertThat(f.progress.getPosition(BIRD[0])).isWithin(0.5).of(25.0)
    }

    // endregion

    // region Completion

    @Test
    fun aNaturalFinishMarksCompletedClearsTheSpotAndAdvances() = test {
        val f = fixture(durations = mapOf(BIRD[0] to 60.0))
        f.startPlaying()
        f.engine.seek(55.0)
        f.runUntil { f.state.currentTrackId == BIRD[1] && f.state.isPlaying }
        assertThat(f.progress.isCompleted(BIRD[0])).isTrue()
        assertThat(f.progress.state.value.listenedCompleted.first()).isEqualTo(BIRD[0])
        assertThat(f.progress.state.value.positions).doesNotContainKey(BIRD[0])
        assertThat(f.state.currentTime).isLessThan(1.0)
        assertThat(f.player.currentMediaItemIndex).isEqualTo(1)
    }

    @Test
    fun skippingPastTheEndFinishesWithoutSavingTheFinishedTalkAgain() = test {
        val f = fixture(durations = mapOf(BIRD[0] to 60.0))
        f.startPlaying()
        f.engine.seek(40.0)
        f.engine.skipForward(30.0)
        assertThat(f.state.currentTrackId).isEqualTo(BIRD[1])
        assertThat(f.progress.isCompleted(BIRD[0])).isTrue()
        assertThat(f.progress.getPosition(BIRD[0])).isEqualTo(0.0)
        f.runUntil { f.state.isPlaying }
        advanceTimeBy(10_001)
        assertThat(f.progress.getPosition(BIRD[0])).isEqualTo(0.0)
    }

    @Test
    fun smartDeleteRemovesTheFinishedDownloadOnlyWhenOn() = test {
        val off = fixture(durations = mapOf(BIRD[0] to 60.0))
        off.startPlaying()
        off.engine.skipForward(120.0)
        assertThat(off.downloads.downloadedIDs.value).contains(BIRD[0])

        val on = fixture(durations = mapOf(BIRD[0] to 60.0), settings = UserSettings(smartDelete = true))
        on.startPlaying()
        on.engine.skipForward(120.0)
        assertThat(on.downloads.downloadedIDs.value).doesNotContain(BIRD[0])
        assertThat(on.state.currentTrackId).isEqualTo(BIRD[1])
    }

    @Test
    fun withAutoPlayOffAFinishStopsAndUnloads() = test {
        val f = fixture(durations = mapOf(BIRD[0] to 60.0), settings = UserSettings(autoPlayNext = false))
        f.startPlaying()
        f.engine.seek(57.0)
        f.runUntil { !f.state.hasTrack }
        assertThat(f.state.isPlaying).isFalse()
        assertThat(f.progress.isCompleted(BIRD[0])).isTrue()
        assertThat(f.player.mediaItemCount).isEqualTo(0)
    }

    @Test
    fun theLastTalkFinishingNaturallyUnloadsWhenNothingFollows() = test {
        val f = fixture(downloaded = setOf(BIRD[2]), durations = mapOf(BIRD[2] to 60.0))
        f.startPlaying(BIRD[2])
        f.engine.seek(57.0)
        f.runUntil { !f.state.hasTrack }
        assertThat(f.progress.isCompleted(BIRD[2])).isTrue()
        assertThat(f.state.isPlaying).isFalse()
        assertThat(f.state.currentTime).isEqualTo(60.0)
    }

    @Test
    fun endOfDiscourseSleepStopsInsteadOfAdvancing() = test {
        val sleep = FakeSleepTimer()
        val f = fixture(durations = mapOf(BIRD[0] to 60.0), sleepTimer = sleep)
        sleep.startUntilEndOfDiscourse()
        f.startPlaying()
        f.engine.seek(57.0)
        f.runUntil { !f.state.hasTrack }
        assertThat(sleep.expirations).isEqualTo(1)
        assertThat(f.progress.isCompleted(BIRD[0])).isTrue()
    }

    @Test
    fun aCountdownSleepTimerDoesNotStopAutoPlay() = test {
        val sleep = FakeSleepTimer()
        val f = fixture(durations = mapOf(BIRD[0] to 60.0), sleepTimer = sleep)
        sleep.start(30)
        f.startPlaying()
        f.engine.skipForward(120.0)
        assertThat(f.state.currentTrackId).isEqualTo(BIRD[1])
        assertThat(sleep.expirations).isEqualTo(0)
    }

    @Test
    fun anExhaustedQueueFallsBackToTheNextDownloadedTalk() = test {
        val f = fixture(downloaded = setOf(BIRD[0], BIRD[2]), durations = mapOf(BIRD[0] to 60.0))
        f.engine.playQueue(listOf(f.item(BIRD[0])))
        f.runUntil { f.state.isPlaying }
        f.engine.skipForward(120.0)
        assertThat(f.state.currentTrackId).isEqualTo(BIRD[2])
        assertThat(f.state.queue.map { it.id }).containsExactly(BIRD[0], BIRD[2]).inOrder()
        f.runUntil { f.state.isPlaying }
        assertThat(f.player.currentMediaItem?.mediaId).isEqualTo(BIRD[2])
    }

    @Test
    fun smartDownloadFetchesTheNextTalkTwentySecondsBeforeTheEnd() = test {
        val f = fixture(downloaded = setOf(BIRD[0]), durations = mapOf(BIRD[0] to 1_200.0))
        f.startPlaying()
        f.engine.seek(1_175.0)
        advanceTimeBy(600)
        assertThat(f.downloads.downloadedIDs.value).doesNotContain(BIRD[1])

        f.playUntil(1_181.0)
        advanceTimeBy(600)
        assertThat(f.downloads.downloadedIDs.value).contains(BIRD[1])
        assertThat(f.downloads.downloadedIDs.value).doesNotContain(BIRD[2])
    }

    @Test
    fun smartDownloadOffNeverFetches() = test {
        val f = fixture(downloaded = setOf(BIRD[0]), durations = mapOf(BIRD[0] to 60.0), settings = UserSettings(smartDownload = false))
        f.startPlaying()
        advanceTimeBy(1_000)
        f.engine.skipForward(120.0)
        assertThat(f.downloads.downloadedIDs.value).containsExactly(BIRD[0])
    }

    @Test
    fun smartDownloadSkipsTalksAlreadyOnDisk() = test {
        val f = fixture(downloaded = setOf(BIRD[0], BIRD[1]), durations = mapOf(BIRD[0] to 300.0))
        f.startPlaying()
        f.engine.seek(285.0)
        advanceTimeBy(600)
        assertThat(f.downloads.downloadedIDs.value).contains(BIRD[2])
    }

    // endregion

    // region System events

    @Test
    fun aTransientFocusLossPausesAndResumesWhenFocusReturns() = test {
        val f = fixture()
        f.startPlaying()
        val audio = shadowOf(context.getSystemService(AudioManager::class.java))
        // ExoPlayer requests focus from its playback thread.
        f.runUntil { audio.lastAudioFocusRequest != null }
        val focus = audio.lastAudioFocusRequest

        focus.listener.onAudioFocusChange(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT)
        f.runUntil { !f.state.isPlaying }
        assertThat(f.player.playWhenReady).isTrue()

        focus.listener.onAudioFocusChange(AudioManager.AUDIOFOCUS_GAIN)
        f.runUntil { f.state.isPlaying }
    }

    @Test
    fun aPermanentFocusLossPausesSavesAndStaysPaused() = test {
        val f = fixture()
        f.startPlaying()
        f.playUntil(12.0)
        val audio = shadowOf(context.getSystemService(AudioManager::class.java))
        f.runUntil { audio.lastAudioFocusRequest != null }
        val focus = audio.lastAudioFocusRequest
        focus.listener.onAudioFocusChange(AudioManager.AUDIOFOCUS_LOSS)
        f.runUntil { !f.state.isPlaying }
        assertThat(f.player.playWhenReady).isFalse()
        assertThat(f.progress.getPosition(BIRD[0])).isAtLeast(12.0)

        focus.listener.onAudioFocusChange(AudioManager.AUDIOFOCUS_GAIN)
        f.settle()
        assertThat(f.state.isPlaying).isFalse()
    }

    @Test
    fun unpluggedHeadphonesPause() = test {
        val f = fixture()
        f.startPlaying()
        context.sendBroadcast(Intent(AudioManager.ACTION_AUDIO_BECOMING_NOISY))
        f.runUntil { !f.state.isPlaying }
        assertThat(f.player.playWhenReady).isFalse()
    }

    @Test
    fun aFailedLoadRetriesFromTheSavedPosition() = test {
        val f = fixture(progress = PlaybackProgress(positions = mapOf(BIRD[0] to 12.0)), failing = setOf(BIRD[0]))
        f.engine.play(BIRD[0])
        f.runUntil { f.state.error != null }
        assertThat(f.state.isPlaying).isFalse()
        assertThat(f.state.error?.message).isEqualTo("Playback could not start. Try playing the discourse again.")

        f.sources.failing.clear()
        f.engine.resume()
        f.runUntil { f.state.isPlaying }
        assertThat(f.state.error).isNull()
        assertThat(f.state.currentTime).isWithin(0.5).of(12.0)
    }

    @Test
    fun theDenoiseSeamHearsSeeksAndItemChangesAndItsStatusIsShown() = test {
        val f = fixture(settings = UserSettings(noiseReduction = true))
        f.startPlaying()
        val afterLoad = f.pipeline.discontinuities
        assertThat(afterLoad).isAtLeast(1)
        f.engine.seek(90.0)
        assertThat(f.pipeline.discontinuities).isEqualTo(afterLoad + 1)
        f.engine.skipToNext()
        assertThat(f.pipeline.discontinuities).isEqualTo(afterLoad + 2)

        assertThat(f.state.isBoostAvailable).isFalse()
        f.pipeline.status.value = AudioProcessingStatus.Active
        assertThat(f.state.audioProcessingStatus).isEqualTo(AudioProcessingStatus.Active)
        assertThat(f.state.isBoostAvailable).isTrue()
    }

    // endregion
}
