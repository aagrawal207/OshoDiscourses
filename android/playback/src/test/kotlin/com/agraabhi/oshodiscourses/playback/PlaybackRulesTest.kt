package com.agraabhi.oshodiscourses.playback

import com.google.common.truth.Truth.assertThat
import org.junit.Test

/** Ports iOS `SkipOutcomeTests`, `AutoPlayNextTests`, `AudioSessionInterruptionTests` and the listening-delta rule. */
class PlaybackRulesTest {
    // Skip arithmetic

    @Test
    fun twoForwardSkipsAccumulateFromTheLastTarget() {
        assertThat(PlaybackRules.skipForwardOutcome(anchor = 100.0, seconds = 30.0, duration = 3600.0)).isEqualTo(SkipOutcome.Seek(130.0))
        assertThat(PlaybackRules.skipForwardOutcome(anchor = 130.0, seconds = 30.0, duration = 3600.0)).isEqualTo(SkipOutcome.Seek(160.0))
    }

    @Test
    fun forwardSkipAdvancesByTheInterval() {
        assertThat(PlaybackRules.skipForwardOutcome(0.0, 30.0, 600.0)).isEqualTo(SkipOutcome.Seek(30.0))
    }

    @Test
    fun forwardSkipWithinOneSecondOfTheEndFinishes() {
        assertThat(PlaybackRules.skipForwardOutcome(3599.0, 30.0, 3600.0)).isEqualTo(SkipOutcome.Finish)
        assertThat(PlaybackRules.skipForwardOutcome(3569.0, 30.0, 3600.0)).isEqualTo(SkipOutcome.Finish)
    }

    @Test
    fun forwardSkipJustShortOfTheEndSeeks() {
        assertThat(PlaybackRules.skipForwardOutcome(3560.0, 30.0, 3600.0)).isEqualTo(SkipOutcome.Seek(3590.0))
    }

    @Test
    fun forwardSkipWithUnknownDurationNeverFinishes() {
        assertThat(PlaybackRules.skipForwardOutcome(5.0, 30.0, 0.0)).isEqualTo(SkipOutcome.Seek(35.0))
        assertThat(PlaybackRules.skipForwardOutcome(5.0, 30.0, -1.0)).isEqualTo(SkipOutcome.Seek(35.0))
    }

    @Test
    fun backwardSkipsSubtractAccumulateAndClampAtZero() {
        assertThat(PlaybackRules.skipBackwardTarget(100.0, 15.0)).isEqualTo(85.0)
        assertThat(PlaybackRules.skipBackwardTarget(85.0, 15.0)).isEqualTo(70.0)
        assertThat(PlaybackRules.skipBackwardTarget(10.0, 15.0)).isEqualTo(0.0)
    }

    @Test
    fun nearEndSeekNeedsAKnownDuration() {
        assertThat(PlaybackRules.isNearEndSeek(target = 596.0, duration = 600.0)).isTrue()
        assertThat(PlaybackRules.isNearEndSeek(target = 594.0, duration = 600.0)).isFalse()
        assertThat(PlaybackRules.isNearEndSeek(target = 10.0, duration = 0.0)).isFalse()
    }

    // Auto-Play Next stays download-only

    private val series = listOf("s-1", "s-2", "s-3", "s-4")

    @Test
    fun advancesToTheImmediateNextWhenDownloaded() {
        assertThat(PlaybackRules.nextDownloadedId("s-1", series) { true }).isEqualTo("s-2")
    }

    @Test
    fun skipsAGapToTheNextDownloaded() {
        val onDisk = setOf("s-1", "s-3", "s-4")
        assertThat(PlaybackRules.nextDownloadedId("s-1", series) { it in onDisk }).isEqualTo("s-3")
    }

    @Test
    fun returnsNullWhenNothingAheadIsDownloaded() {
        assertThat(PlaybackRules.nextDownloadedId("s-1", series) { it == "s-1" }).isNull()
    }

    @Test
    fun returnsNullAtTheEndOfTheSeries() {
        assertThat(PlaybackRules.nextDownloadedId("s-4", series) { true }).isNull()
    }

    @Test
    fun neverAdvancesBackwards() {
        assertThat(PlaybackRules.nextDownloadedId("s-3", series) { it == "s-1" }).isNull()
    }

    @Test
    fun returnsNullForAnUnknownCurrent() {
        assertThat(PlaybackRules.nextDownloadedId("elsewhere", series) { true }).isNull()
    }

    // Interruption resume decision

    @Test
    fun resumesWhenPlayingBeforeAndTheSystemAllows() {
        assertThat(PlaybackRules.shouldResumeAfterInterruption(wasPlaying = true, systemAllowsResume = true)).isTrue()
    }

    @Test
    fun staysPausedWhenPausedBeforeTheInterruption() {
        assertThat(PlaybackRules.shouldResumeAfterInterruption(wasPlaying = false, systemAllowsResume = true)).isFalse()
    }

    @Test
    fun staysPausedWhenTheSystemWithholdsResume() {
        assertThat(PlaybackRules.shouldResumeAfterInterruption(wasPlaying = true, systemAllowsResume = false)).isFalse()
    }

    @Test
    fun staysPausedWhenNeitherHolds() {
        assertThat(PlaybackRules.shouldResumeAfterInterruption(wasPlaying = false, systemAllowsResume = false)).isFalse()
    }

    // Listening time between 10 s ticks

    @Test
    fun normalTickIsContinuous() {
        assertThat(PlaybackRules.isContinuousListening(delta = 10.0, rate = 1f)).isTrue()
    }

    @Test
    fun doubleSpeedTickIsContinuous() {
        assertThat(PlaybackRules.isContinuousListening(delta = 20.0, rate = 2f)).isTrue()
        assertThat(PlaybackRules.isContinuousListening(delta = 25.0, rate = 2f)).isTrue()
        assertThat(PlaybackRules.isContinuousListening(delta = 25.5, rate = 2f)).isFalse()
    }

    @Test
    fun seeksAreNotListening() {
        assertThat(PlaybackRules.isContinuousListening(delta = 120.0, rate = 1f)).isFalse()
        assertThat(PlaybackRules.isContinuousListening(delta = 120.0, rate = 2f)).isFalse()
        assertThat(PlaybackRules.isContinuousListening(delta = -30.0, rate = 1f)).isFalse()
        assertThat(PlaybackRules.isContinuousListening(delta = 0.0, rate = 1f)).isFalse()
    }

    @Test
    fun slowRatesKeepTheNormalWindow() {
        assertThat(PlaybackRules.isContinuousListening(delta = 12.0, rate = 0.5f)).isTrue()
        assertThat(PlaybackRules.isContinuousListening(delta = 15.0, rate = 0.5f)).isTrue()
    }

    // Smart Download lead and resume positions

    @Test
    fun smartDownloadFiresTwentySecondsBeforeTheEnd() {
        assertThat(PlaybackRules.shouldTriggerSmartDownload(position = 3580.0, duration = 3600.0)).isTrue()
        assertThat(PlaybackRules.shouldTriggerSmartDownload(position = 3579.0, duration = 3600.0)).isFalse()
    }

    @Test
    fun smartDownloadWaitsForAKnownUsefulDuration() {
        assertThat(PlaybackRules.shouldTriggerSmartDownload(position = 0.0, duration = 0.0)).isFalse()
        assertThat(PlaybackRules.shouldTriggerSmartDownload(position = 20.0, duration = 30.0)).isFalse()
        assertThat(PlaybackRules.shouldTriggerSmartDownload(position = 220.0, duration = 240.0)).isTrue()
    }

    @Test
    fun savedPositionResumesOnlyWhenClearOfTheEnd() {
        assertThat(PlaybackRules.startPosition(explicit = null, saved = 120.0, duration = 600.0)).isEqualTo(120.0)
        assertThat(PlaybackRules.startPosition(explicit = null, saved = 596.0, duration = 600.0)).isNull()
        assertThat(PlaybackRules.startPosition(explicit = null, saved = 0.0, duration = 600.0)).isNull()
        assertThat(PlaybackRules.startPosition(explicit = null, saved = 120.0, duration = 0.0)).isNull()
    }

    @Test
    fun explicitPositionIsClampedShortOfTheEnd() {
        assertThat(PlaybackRules.startPosition(explicit = 600.0, saved = 0.0, duration = 600.0)).isEqualTo(599.0)
        assertThat(PlaybackRules.startPosition(explicit = 42.0, saved = 300.0, duration = 600.0)).isEqualTo(42.0)
        assertThat(PlaybackRules.startPosition(explicit = -3.0, saved = 300.0, duration = 600.0)).isEqualTo(0.0)
    }
}
