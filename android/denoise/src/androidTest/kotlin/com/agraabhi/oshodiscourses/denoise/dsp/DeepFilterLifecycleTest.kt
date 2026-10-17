package com.agraabhi.oshodiscourses.denoise.dsp

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.agraabhi.oshodiscourses.core.domain.player.DeepFilterStatus
import com.agraabhi.oshodiscourses.core.model.NoiseReductionMode
import com.agraabhi.oshodiscourses.core.model.VoiceFocusPreset
import com.agraabhi.oshodiscourses.denoise.dsp.NativeFixtures.waitForActive
import com.google.common.truth.Truth.assertThat
import com.google.common.truth.Truth.assertWithMessage
import kotlin.math.PI
import kotlin.math.sin
import org.junit.Test
import org.junit.runner.RunWith

/** Async load and configuration races (iOS `DeepFilterLifecycleTests`). */
@RunWith(AndroidJUnit4::class)
class DeepFilterLifecycleTest {
    @Test
    fun invalidatingAnInFlightLoadPreventsReactivation() {
        val processor = NativeFixtures.deepFilter()
        processor.activate(1, 1024, 48_000.0)
        processor.invalidate()
        Thread.sleep(2_000)
        assertThat(processor.currentStatus).isEqualTo(DeepFilterStatus.Idle)
        val input = FloatArray(480) { 0.2f }
        assertThat(NativeFixtures.process(processor, input)).isFalse()
        assertThat(input.all { it == 0.2f }).isTrue()
    }

    @Test
    fun unsupportedPcmFormatCancelsAnOlderLoad() {
        val processor = NativeFixtures.processor()
        processor.configure(NoiseReductionMode.DEEP_FILTER_NET, 0.5f, 0.7f, 12f, VoiceFocusPreset.FOCUS)
        processor.prepare(1, 480, 48_000.0)
        processor.prepare(1, 480, 48_000.0, isSupportedPcm = false)
        Thread.sleep(2_000)
        assertThat(processor.deepFilter.currentStatus).isEqualTo(DeepFilterStatus.UnsupportedAudioFormat)
        assertThat(processor.deepFilter.currentStatus.isBypassing).isTrue()
        val samples = FloatArray(480) { 0.2f }
        Buffers.processMono(processor, samples)
        assertThat(samples.all { it == 0.2f }).isTrue()
        assertThat(processor.diagnosticsSnapshot().unpreparedBuffers).isEqualTo(1)
    }

    @Test
    fun changingOnlyConfigurationDoesNotResetTheAudioStream() {
        fun make() = NativeFixtures.ready(NoiseReductionMode.DEEP_FILTER_NET, maxFrames = 480, sampleRate = 48_000.0)
        val changed = make()
        val reference = make()
        for (pass in 0 until 100) {
            if (pass == 40) changed.configure(NoiseReductionMode.DEEP_FILTER_NET, 0.5f, 0.7f, 12f, VoiceFocusPreset.FOCUS)
            val expected = Signals.sine(317.0, 48_000.0, 480, amplitude = 0.2, startIndex = pass * 480)
            val actual = expected.copyOf()
            Buffers.processMono(changed, actual)
            Buffers.processMono(reference, expected)
            assertWithMessage("configuration inserted a priming gap").that(Signals.maxDifference(actual, expected)).isLessThan(0.00001f)
        }
    }

    @Test
    fun liveStrengthFocusAndBoostKeepNeuralHistory() {
        val processor = NativeFixtures.processor()
        processor.configure(NoiseReductionMode.DEEP_FILTER_NET, 0.5f, 0.7f, 12f, VoiceFocusPreset.FOCUS)
        val context = checkNotNull(processor.makeTapContext(1))
        context.prepare(1, 1024, 22_050.0)
        waitForActive(processor.deepFilter)
        val read = SourceRead()
        val signal = Signals.syllables(4.0, 22_050.0)
        var offset = 0
        var step = 0
        while (offset + 1024 <= signal.size) {
            when (step++) {
                10 -> processor.configure(NoiseReductionMode.DEEP_FILTER_NET, 0.5f, 0.7f, 100f, VoiceFocusPreset.STRONG)
                20 -> processor.setOutputGain(3f)
                30 -> processor.configure(NoiseReductionMode.DEEP_FILTER_NET, 0.5f, 0.7f, 6f, VoiceFocusPreset.LIFT, outputGain = 2f)
            }
            val block = signal.copyOfRange(offset, offset + 1024)
            assertThat(context.processSourceAudio(arrayOf(block), Buffers.MONO, read.set(1024))).isTrue()
            assertThat(block.all { it.isFinite() && kotlin.math.abs(it) <= 1f }).isTrue()
            offset += 1024
        }
        val snapshot = processor.diagnosticsSnapshot()
        assertThat(snapshot.streamResets).isEqualTo(0)
        assertThat(snapshot.modelBypassedBuffers).isEqualTo(0)
        assertThat(snapshot.preparations).isEqualTo(1)
    }

    @Test
    fun interleavedDeepFilterAudioIsDenoisedAndRemainsMono() {
        val processor = NativeFixtures.ready(NoiseReductionMode.DEEP_FILTER_NET, channels = 2)
        for (pass in 0 until 10) {
            val input = FloatArray(2048) { index -> (if (index % 2 == 0) 0.2f else 0.1f) * sin((index / 2 + pass * 1024) * 0.1f) }
            processor.process(arrayOf(input), intArrayOf(2), 1024)
            assertThat((0 until 1024).all { input[it * 2] == input[it * 2 + 1] }).isTrue()
            assertThat(input.all { it.isFinite() }).isTrue()
        }
        assertThat(processor.diagnosticsSnapshot().processedBuffers).isEqualTo(10)
    }

    @Test
    fun retiredModelLoadCannotBecomeTheCurrentModel() {
        val processor = NativeFixtures.processor()
        processor.configure(NoiseReductionMode.DEEP_FILTER_NET, 0.5f, 0.7f, 12f, VoiceFocusPreset.FOCUS)
        val old = checkNotNull(processor.makeTapContext(20))
        old.prepare(1, 1024, 22_050.0)
        val current = checkNotNull(processor.makeTapContext(21))
        current.prepare(1, 1024, 22_050.0)
        waitForActive(current.stream.deepFilter)
        old.stream.deepFilter.activate(1, 1024, 48_000.0)
        val read = SourceRead()
        old.processSourceAudio(arrayOf(FloatArray(1024) { 0.8f }), Buffers.MONO, read.set(1024, status = -50))
        current.processSourceAudio(arrayOf(FloatArray(1024) { 0.3f * sin(it * 0.1f) }), Buffers.MONO, read.set(1024))
        val snapshot = processor.diagnosticsSnapshot()
        assertThat(snapshot.tapGeneration).isEqualTo(21L)
        assertThat(snapshot.isPrepared).isTrue()
        assertThat(snapshot.deepFilterStatus).isEqualTo(DeepFilterStatus.Active)
        assertThat(snapshot.processedBuffers).isEqualTo(1)
        assertThat(snapshot.sourceReadFailures).isEqualTo(0)
        assertThat(old.stream.deepFilter.currentStatus).isEqualTo(DeepFilterStatus.Idle)
    }

    @Test
    fun voiceFocusPresetsChangeTheModelOutput() {
        val signal = FloatArray(48_000) { index -> (0.2 * sin(2 * PI * 220 * index / 48_000.0)).toFloat() * if ((index / 9_600) % 2 == 0) 1f else 0.02f }
        fun render(preset: VoiceFocusPreset): FloatArray {
            val processor = NativeFixtures.processor()
            processor.configure(NoiseReductionMode.DEEP_FILTER_NET, 0.5f, 0.7f, 12f, preset)
            processor.prepare(1, 1024, 48_000.0)
            waitForActive(processor.deepFilter)
            return Buffers.render(processor, signal, 1024)
        }
        val focus = render(VoiceFocusPreset.FOCUS)
        val strong = render(VoiceFocusPreset.STRONG)
        assertThat(Signals.maxDifference(focus, strong)).isGreaterThan(0.001f)
    }
}
