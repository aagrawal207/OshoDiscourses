package com.agraabhi.oshodiscourses.denoise.dsp

import com.agraabhi.oshodiscourses.core.model.NoiseReductionMode
import com.agraabhi.oshodiscourses.core.model.VoiceFocusPreset
import com.google.common.truth.Truth.assertThat
import org.junit.Test

class SourceAudioTimelineTest {
    private val frames1024 = MediaTime(1024, 22_050)

    @Test
    fun sequentialRangesAndChangingPlaybackSpeedsRemainContinuous() {
        val timeline = SourceAudioTimeline()
        var start = MediaTime.ZERO
        for (sourceFrames in longArrayOf(1024, 1024, 512, 512, 2048, 2048, 512, 1024)) {
            val range = MediaTimeRange(start, MediaTime(sourceFrames, 22_050))
            val result = timeline.consume(range, 22_050.0)
            assertThat(result.validRange).isTrue()
            assertThat(result.requiresReset || result.timedDiscontinuity).isFalse()
            start = range.end
        }
    }

    @Test
    fun rationalTimebaseRoundingDoesNotLookLikeASeek() {
        val timeline = SourceAudioTimeline()
        for (index in 0 until 100) {
            val exactStart = index * 1024 / 22_050.0
            val scale = if (index % 2 == 0) 600 else 48_000
            val range = MediaTimeRange(MediaTime.fromSeconds(exactStart, scale), MediaTime.fromSeconds(1024 / 22_050.0, scale))
            assertThat(timeline.consume(range, 22_050.0).requiresReset).isFalse()
        }
    }

    @Test
    fun unflaggedForwardAndBackwardSeeksAreDetectedOnce() {
        val timeline = SourceAudioTimeline()
        timeline.consume(MediaTimeRange(MediaTime.ZERO, frames1024), 22_050.0)
        val forward = timeline.consume(MediaTimeRange(MediaTime.fromSeconds(20.0, 22_050), frames1024), 22_050.0)
        assertThat(forward.requiresReset && forward.timedDiscontinuity && forward.gapSeconds > 19).isTrue()
        val backwardsRange = MediaTimeRange(MediaTime.fromSeconds(5.0, 22_050), frames1024)
        val backward = timeline.consume(backwardsRange, 22_050.0)
        assertThat(backward.requiresReset && backward.timedDiscontinuity && backward.gapSeconds < -15).isTrue()
        assertThat(timeline.consume(MediaTimeRange(backwardsRange.end, frames1024), 22_050.0).requiresReset).isFalse()
    }

    @Test
    fun epochChangesAreBoundariesEvenWhenNumericTimesMeet() {
        val timeline = SourceAudioTimeline()
        timeline.consume(MediaTimeRange(MediaTime.ZERO, frames1024), 22_050.0)
        val range = MediaTimeRange(MediaTime(1024, 22_050, epoch = 7), frames1024)
        assertThat(timeline.consume(range, 22_050.0).timedDiscontinuity).isTrue()
        assertThat(timeline.consume(MediaTimeRange(range.end, frames1024), 22_050.0).requiresReset).isFalse()
    }

    @Test
    fun invalidTimingIsNotComparedAsZeroAndCannotBridgeUnknownAudio() {
        val invalidRanges = listOf(
            MediaTimeRange.INVALID,
            MediaTimeRange.ZERO,
            MediaTimeRange(MediaTime.INDEFINITE, MediaTime(1, 1)),
            MediaTimeRange(MediaTime.ZERO, MediaTime.POSITIVE_INFINITY),
            MediaTimeRange(MediaTime.ZERO, MediaTime(-1, 1)),
        )
        for (invalid in invalidRanges) {
            val timeline = SourceAudioTimeline()
            timeline.consume(MediaTimeRange(MediaTime.ZERO, frames1024), 22_050.0)
            val loss = timeline.consume(invalid, 22_050.0)
            assertThat(!loss.validRange && loss.requiresReset && !loss.timedDiscontinuity).isTrue()
            assertThat(timeline.consume(invalid, 22_050.0).requiresReset).isFalse()
            val restored = timeline.consume(MediaTimeRange(frames1024, frames1024), 22_050.0)
            assertThat(restored.validRange && restored.requiresReset && !restored.timedDiscontinuity).isTrue()
        }
    }

    @Test
    fun explicitStartReanchorsWithoutASecondInferredBoundary() {
        val timeline = SourceAudioTimeline()
        timeline.consume(MediaTimeRange(MediaTime.ZERO, frames1024), 22_050.0)
        val result = timeline.consume(MediaTimeRange(MediaTime(20, 1), frames1024), 22_050.0, startsStream = true)
        assertThat(result.validRange && !result.requiresReset).isTrue()
    }

    /** Cadence stands in for the native modes, which run in the instrumented suite. */
    @Test
    fun timeJumpKeepsWholeStereoBufferRawAndDiscardsOldHistory() {
        val processor = NoiseReductionProcessor()
        processor.configure(NoiseReductionMode.CADENCE, 0.5f, 0.7f, 12f, VoiceFocusPreset.FOCUS, outputGain = 2f)
        val context = checkNotNull(processor.makeTapContext(9))
        context.prepare(2, 1024, 22_050.0)
        assertThat(processor.diagnosticsSnapshot().isPrepared).isTrue()
        val read = SourceRead()
        fun send(value: Float, range: MediaTimeRange): FloatArray {
            val samples = FloatArray(2048) { if (it % 2 == 0) value else -value * 0.5f }
            context.processSourceAudio(arrayOf(samples), intArrayOf(2), read.set(1024, timeRange = range))
            return samples
        }
        for (index in 0 until 20) send(0.4f, MediaTimeRange(MediaTime(index * 1024L, 22_050), frames1024))
        val seek = MediaTimeRange(MediaTime(20, 1), frames1024)
        val first = send(0.2f, seek)
        assertThat(read.startOfStream).isTrue()
        assertThat(first.withIndex().all { (index, value) -> value == if (index % 2 == 0) 0.2f else -0.1f }).isTrue()
        awaitReset(processor)
        var next = seek.end
        repeat(10) {
            val range = MediaTimeRange(next, frames1024)
            assertThat(send(0f, range).all { kotlin.math.abs(it) < 0.0001f }).isTrue()
            next = range.end
        }
        val state = processor.diagnosticsSnapshot()
        assertThat(state.tapGeneration).isEqualTo(9L)
        assertThat(state.sourceTimeDiscontinuities).isEqualTo(1)
        assertThat(state.sourceTimeResets).isEqualTo(1)
        assertThat(state.sourceDiscontinuities).isEqualTo(1)
        assertThat(state.streamResets).isEqualTo(1)
        assertThat(state.invalidSourceTimeRanges).isEqualTo(0)
    }
}
