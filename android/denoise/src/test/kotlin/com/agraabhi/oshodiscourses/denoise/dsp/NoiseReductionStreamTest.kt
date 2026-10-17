package com.agraabhi.oshodiscourses.denoise.dsp

import com.agraabhi.oshodiscourses.core.model.NoiseReductionMode
import com.agraabhi.oshodiscourses.core.model.VoiceFocusPreset
import com.google.common.truth.Truth.assertThat
import org.junit.Test

/** The pure-Kotlin half of the iOS `NoiseReductionProcessorTests`. */
class NoiseReductionStreamTest {
    private fun processCadence(input: FloatArray, sampleRate: Double): FloatArray {
        val processor = NoiseReductionProcessor()
        processor.configure(NoiseReductionMode.CADENCE, 0f, 1f, 100f, VoiceFocusPreset.FOCUS)
        processor.prepare(1, input.size, sampleRate)
        return input.copyOf().also { Buffers.processMono(processor, it) }
    }

    @Test
    fun cadenceAttenuatesMainsHum() {
        val input = Signals.sine(60.0, 48_000.0, 48_000, amplitude = 0.2)
        val output = processCadence(input, 48_000.0)
        assertThat(Signals.rms(output, output.size / 2)).isLessThan(Signals.rms(input) * 0.35f)
    }

    @Test
    fun cadencePreservesVoiceBandTone() {
        val input = Signals.sine(440.0, 48_000.0, 48_000, amplitude = 0.2)
        val output = processCadence(input, 48_000.0)
        assertThat(Signals.rms(output, output.size / 2)).isGreaterThan(Signals.rms(input) * 0.8f)
    }

    @Test
    fun cadenceInterleavedStereoMatchesPlanarProcessing() {
        fun processor() = NoiseReductionProcessor().apply {
            configure(NoiseReductionMode.CADENCE, 0.5f, 1f, 12f, VoiceFocusPreset.FOCUS)
            prepare(2, 4096, 22_050.0)
        }
        val planarProcessor = processor()
        val interleavedProcessor = processor()
        val planar = Buffers.Block(2, 4096, interleaved = false)
        val interleaved = Buffers.Block(2, 4096, interleaved = true)
        for (pass in 0 until 4) {
            planar.fill(pass * 4096)
            interleaved.fill(pass * 4096)
            planarProcessor.process(planar.buffers, planar.lanes, 4096)
            interleavedProcessor.process(interleaved.buffers, interleaved.lanes, 4096)
            for (lane in 0 until 2) {
                for (frame in 0 until 4096) assertThat(interleaved[lane, frame]).isWithin(0.00001f).of(planar[lane, frame])
            }
        }
    }

    @Test
    fun shortBufferIsLeftUntouchedInsteadOfReadingPastItsEnd() {
        val processor = NoiseReductionProcessor()
        processor.prepare(1, 1024, 48_000.0)
        val samples = floatArrayOf(0.1f, -0.2f, 0.3f)
        Buffers.processMono(processor, samples, frameCount = 1024)
        assertThat(samples.toList()).containsExactly(0.1f, -0.2f, 0.3f).inOrder()
        val diagnostics = processor.diagnosticsSnapshot()
        assertThat(diagnostics.invalidBuffers).isEqualTo(1)
        assertThat(diagnostics.processedBuffers).isEqualTo(0)
        assertThat(diagnostics.modelBypassedBuffers).isEqualTo(0)
    }

    @Test
    fun diagnosticsDistinguishProcessedDisabledAndUnpreparedAudio() {
        val processor = NoiseReductionProcessor()
        val input = FloatArray(480) { 0.2f }
        Buffers.processMono(processor, input)
        processor.configure(NoiseReductionMode.CADENCE, 0.5f, 0.7f, 12f, VoiceFocusPreset.FOCUS)
        processor.prepare(1, 480, 48_000.0)
        Buffers.processMono(processor, input)
        processor.setDenoiseEnabled(false)
        Buffers.processMono(processor, input)
        val diagnostics = processor.diagnosticsSnapshot()
        assertThat(diagnostics.processedBuffers).isEqualTo(1)
        assertThat(diagnostics.disabledBuffers).isEqualTo(1)
        assertThat(diagnostics.unpreparedBuffers).isEqualTo(1)
        assertThat(diagnostics.invalidBuffers).isEqualTo(0)
        assertThat(diagnostics.modelBypassedBuffers).isEqualTo(0)
        assertThat(diagnostics.lockContendedBuffers).isEqualTo(0)
    }

    @Test
    fun noiseProcessorRoutesDeepFilterNetWithoutEmittingSilence() {
        val processor = NoiseReductionProcessor()
        processor.configure(NoiseReductionMode.DEEP_FILTER_NET, 1f, 1f, 12f, VoiceFocusPreset.FOCUS)
        processor.prepare(1, 480, 22_050.0)
        val samples = FloatArray(480) { 0.5f }
        Buffers.processMono(processor, samples)
        assertThat(samples.all { it == 0.5f }).isTrue()
        val diagnostics = processor.diagnosticsSnapshot()
        assertThat(diagnostics.modelBypassedBuffers).isEqualTo(1)
        assertThat(diagnostics.processedBuffers).isEqualTo(0)
    }

    @Test
    fun missingModelIsReportedNotSubstituted() {
        val processor = NoiseReductionProcessor()
        processor.configure(NoiseReductionMode.DEEP_FILTER_NET, 0.5f, 0.7f, 12f, VoiceFocusPreset.FOCUS)
        processor.prepare(1, 480, 48_000.0)
        assertThat(awaitCondition { processor.deepFilter.currentStatus.isBypassing && processor.deepFilter.currentStatus != com.agraabhi.oshodiscourses.core.domain.player.DeepFilterStatus.Loading }).isTrue()
        assertThat(processor.deepFilter.currentStatus.isBypassing).isTrue()
    }

    @Test
    fun unsupportedRatesAreRejectedAndLeftRaw() {
        val processor = NoiseReductionProcessor()
        processor.configure(NoiseReductionMode.CADENCE, 0.5f, 0.7f, 12f, VoiceFocusPreset.FOCUS)
        processor.prepare(1, 480, 1_000.0)
        val samples = FloatArray(480) { 0.25f }
        Buffers.processMono(processor, samples)
        assertThat(samples.all { it == 0.25f }).isTrue()
        assertThat(processor.deepFilter.currentStatus)
            .isEqualTo(com.agraabhi.oshodiscourses.core.domain.player.DeepFilterStatus.UnsupportedAudioFormat)
        assertThat(processor.diagnosticsSnapshot().unpreparedBuffers).isEqualTo(1)
    }
}
