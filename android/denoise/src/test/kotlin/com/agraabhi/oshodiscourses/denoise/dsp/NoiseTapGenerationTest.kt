package com.agraabhi.oshodiscourses.denoise.dsp

import com.agraabhi.oshodiscourses.core.domain.player.DeepFilterStatus
import com.agraabhi.oshodiscourses.core.model.NoiseReductionMode
import com.agraabhi.oshodiscourses.core.model.VoiceFocusPreset
import com.google.common.truth.Truth.assertThat
import org.junit.Test

/**
 * Generation ownership from iOS `NoiseTapGenerationTests`. Preparation is inline here, so the
 * iOS deferred-preparation races have no Android counterpart.
 */
class NoiseTapGenerationTest {
    private val read = SourceRead()

    private fun configured(mode: NoiseReductionMode = NoiseReductionMode.CADENCE) = NoiseReductionProcessor().apply {
        configure(mode, 0.5f, 0.7f, 12f, VoiceFocusPreset.FOCUS)
    }

    private fun send(
        context: NoiseReductionTapContext,
        value: Float,
        startOfStream: Boolean = false,
        status: Int = 0,
        frames: Int = 1024,
    ): FloatArray {
        val samples = FloatArray(1024) { value }
        context.processSourceAudio(arrayOf(samples), Buffers.MONO, read.set(1024, frames, startOfStream, status))
        return samples
    }

    @Test
    fun theRequestedContextIsCurrentUntilRetired() {
        val processor = configured()
        val context = checkNotNull(processor.makeTapContext(7))
        assertThat(context.generation).isEqualTo(7)
        assertThat(processor.diagnosticsSnapshot().tapGeneration).isEqualTo(7L)
        processor.retireTap(7)
        assertThat(context.isRetired).isTrue()
        assertThat(processor.diagnosticsSnapshot().tapGeneration).isNull()
    }

    @Test
    fun replacingATapStartsItsOwnCountersAndIgnoresOldCallbacks() {
        val processor = configured()
        val old = checkNotNull(processor.makeTapContext(10))
        old.prepare(1, 1024, 22_050.0)
        send(old, 0.25f)
        assertThat(processor.diagnosticsSnapshot().processedBuffers).isEqualTo(1)

        val current = checkNotNull(processor.makeTapContext(11))
        var snapshot = processor.diagnosticsSnapshot()
        assertThat(snapshot.tapGeneration).isEqualTo(11L)
        assertThat(snapshot.isPrepared).isFalse()
        assertThat(snapshot.processedBuffers).isEqualTo(0)
        current.prepare(1, 1024, 22_050.0)
        send(current, 0.3f)
        val before = processor.diagnosticsSnapshot()

        old.prepare(8, 12, 8_000.0)
        old.unprepare()
        old.requestDiscontinuity()
        processor.requestDiscontinuity(10)
        processor.retireTap(10)
        assertThat(send(old, 0.75f, startOfStream = true).all { it == 0.75f }).isTrue()
        send(old, 0.6f, status = -50)
        assertThat(read.returnedFrames).isEqualTo(0)
        assertThat(read.startOfStream).isFalse()
        snapshot = processor.diagnosticsSnapshot()
        assertThat(snapshot.tapGeneration).isEqualTo(11L)
        assertThat(snapshot.isPrepared).isTrue()
        assertThat(snapshot.processedBuffers).isEqualTo(before.processedBuffers)
        assertThat(snapshot.sourceReadFailures).isEqualTo(before.sourceReadFailures)
        assertThat(snapshot.sourceDiscontinuities).isEqualTo(before.sourceDiscontinuities)
        assertThat(snapshot.resetRequests).isEqualTo(before.resetRequests)
        assertThat(snapshot.streamResets).isEqualTo(before.streamResets)
        assertThat(snapshot.sourceReadFailed || snapshot.resetPending).isFalse()
    }

    @Test
    fun retiredModelLoadCannotBecomeTheCurrentModel() {
        val processor = configured(NoiseReductionMode.DEEP_FILTER_NET)
        val old = checkNotNull(processor.makeTapContext(20))
        old.prepare(1, 1024, 22_050.0)
        val current = checkNotNull(processor.makeTapContext(21))
        current.prepare(1, 1024, 22_050.0)
        old.stream.deepFilter.activate(1, 1024, 48_000.0)
        send(old, 0.8f, status = -50)
        assertThat(old.stream.deepFilter.currentStatus).isEqualTo(DeepFilterStatus.Idle)
        val snapshot = processor.diagnosticsSnapshot()
        assertThat(snapshot.tapGeneration).isEqualTo(21L)
        assertThat(snapshot.isPrepared).isTrue()
        assertThat(snapshot.sourceReadFailures).isEqualTo(0)
    }

    @Test
    fun retirementFencesCanceledGenerationsAndDoesNotRelabelStandaloneData() {
        val processor = configured()
        processor.prepare(1, 16, 22_050.0)
        Buffers.processMono(processor, FloatArray(16) { 0.2f })
        assertThat(processor.diagnosticsSnapshot().tapGeneration).isNull()
        assertThat(processor.diagnosticsSnapshot().processedBuffers).isEqualTo(1)
        val context = checkNotNull(processor.makeTapContext(30))
        assertThat(processor.diagnosticsSnapshot().processedBuffers).isEqualTo(0)
        context.prepare(1, 1024, 22_050.0)
        processor.retireTap(30)
        context.prepare(1, 1024, 48_000.0)
        send(context, 0.5f)
        val snapshot = processor.diagnosticsSnapshot()
        assertThat(snapshot.tapGeneration).isNull()
        assertThat(snapshot.isPrepared).isFalse()
        assertThat(snapshot.processedBuffers).isEqualTo(0)
        assertThat(snapshot.deepFilterStatus).isEqualTo(DeepFilterStatus.Idle)
        assertThat(processor.makeTapContext(30)).isNull()
        processor.retireTap(31)
        assertThat(processor.makeTapContext(31)).isNull()
        assertThat(processor.makeTapContext(32)).isNotNull()
    }

    @Test
    fun sourceDiscontinuityKeepsItsGenerationAndUnprepareClearsReadiness() {
        val processor = configured()
        val context = checkNotNull(processor.makeTapContext(40))
        context.prepare(1, 1024, 22_050.0)
        send(context, 0.7f)
        send(context, 0f, startOfStream = true, frames = 0)
        awaitReset(processor)
        var snapshot = processor.diagnosticsSnapshot()
        assertThat(snapshot.tapGeneration).isEqualTo(40L)
        assertThat(snapshot.isPrepared).isTrue()
        assertThat(snapshot.sourceDiscontinuities).isEqualTo(1)
        assertThat(snapshot.streamResets).isEqualTo(1)
        assertThat(snapshot.resetPending).isFalse()
        context.unprepare()
        snapshot = processor.diagnosticsSnapshot()
        assertThat(snapshot.tapGeneration).isEqualTo(40L)
        assertThat(snapshot.isPrepared).isFalse()
        assertThat(send(context, 0.25f).all { it == 0.25f }).isTrue()
    }

    @Test
    fun liveSettingsKeepTheGenerationAndItsHistory() {
        val processor = configured()
        val context = checkNotNull(processor.makeTapContext(50))
        context.prepare(1, 1024, 22_050.0)
        send(context, 0.4f)
        processor.setOutputGain(3f)
        processor.configure(NoiseReductionMode.CADENCE, 0.6f, 1f, 100f, VoiceFocusPreset.STRONG, outputGain = 2f)
        send(context, 0.4f)
        val snapshot = processor.diagnosticsSnapshot()
        assertThat(snapshot.tapGeneration).isEqualTo(50L)
        assertThat(snapshot.processedBuffers).isEqualTo(2)
        assertThat(snapshot.streamResets).isEqualTo(0)
        assertThat(snapshot.preparations).isEqualTo(1)
    }
}
