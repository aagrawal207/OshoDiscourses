package com.agraabhi.oshodiscourses.denoise.media3

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.AudioProcessor.AudioFormat
import com.agraabhi.oshodiscourses.core.domain.player.AudioProcessingStatus
import com.agraabhi.oshodiscourses.core.domain.settings.UserSettings
import com.agraabhi.oshodiscourses.core.model.NoiseReductionMode
import com.agraabhi.oshodiscourses.core.model.VoiceFocusPreset
import com.agraabhi.oshodiscourses.core.testing.FakeSettingsRepository
import com.agraabhi.oshodiscourses.denoise.DenoiseEngine
import com.agraabhi.oshodiscourses.denoise.dsp.Buffers
import com.agraabhi.oshodiscourses.denoise.dsp.DeepFilterModelSource
import com.agraabhi.oshodiscourses.denoise.dsp.NoiseReductionProcessor
import com.agraabhi.oshodiscourses.denoise.dsp.Signals
import com.google.common.truth.Truth.assertThat
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.After
import org.junit.Test

class NoiseReductionAudioProcessorTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)

    @After
    fun tearDown() = scope.cancel()

    private fun engine(enabled: Boolean, mode: NoiseReductionMode = NoiseReductionMode.CADENCE, boost: Double = 1.0) =
        DenoiseEngine(
            FakeSettingsRepository(UserSettings(noiseReduction = enabled, noiseReductionMode = mode, volumeBoost = boost)),
            DeepFilterModelSource { null },
            scope,
        )

    private fun AudioProcessor.start(format: AudioFormat): AudioProcessor = apply {
        configure(format)
        flush(AudioProcessor.StreamMetadata.DEFAULT)
    }

    /** Queues [input] in ragged pieces and returns everything the processor emitted. */
    private fun AudioProcessor.run(input: ByteArray, bytesPerFrame: Int, pieces: IntArray = intArrayOf(1, 37, 2048, 999, 7, 4096)): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        var offset = 0
        var index = 0
        while (offset < input.size) {
            val frames = pieces[index++ % pieces.size]
            val size = minOf(frames * bytesPerFrame, input.size - offset)
            val buffer = ByteBuffer.allocateDirect(size).order(ByteOrder.nativeOrder())
            buffer.put(input, offset, size).flip()
            queueInput(buffer)
            assertThat(buffer.hasRemaining()).isFalse()
            val output = getOutput()
            val bytes = ByteArray(output.remaining())
            output.get(bytes)
            out.write(bytes)
            offset += size
        }
        return out.toByteArray()
    }

    private fun pcm16(samples: FloatArray): ByteArray {
        val buffer = ByteBuffer.allocate(samples.size * 2).order(ByteOrder.LITTLE_ENDIAN)
        for (sample in samples) buffer.putShort((sample * 32767).toInt().toShort())
        return buffer.array()
    }

    private fun shorts(bytes: ByteArray): ShortArray {
        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        return ShortArray(buffer.remaining()).also { buffer.get(it) }
    }

    private fun floats(samples: FloatArray): ByteArray {
        val buffer = ByteBuffer.allocate(samples.size * 4).order(ByteOrder.LITTLE_ENDIAN)
        for (sample in samples) buffer.putFloat(sample)
        return buffer.array()
    }

    private fun interleave(left: FloatArray, right: FloatArray) = FloatArray(left.size * 2) { if (it % 2 == 0) left[it / 2] else right[it / 2] }

    @Test
    fun disabledChainIsBitExactPassthroughForBothEncodings() {
        val signal = interleave(Signals.speech(1.0, 22_050.0), Signals.sine(300.0, 22_050.0, 22_050))
        val processor = engine(enabled = false).createAudioProcessors().single()
        processor.start(AudioFormat(22_050, 2, C.ENCODING_PCM_16BIT))
        assertThat(processor.isActive).isTrue()
        val input16 = pcm16(signal)
        assertThat(processor.run(input16, 4).toList()).isEqualTo(input16.toList())

        processor.start(AudioFormat(44_100, 2, C.ENCODING_PCM_FLOAT))
        val inputFloat = floats(signal)
        assertThat(processor.run(inputFloat, 8).toList()).isEqualTo(inputFloat.toList())
    }

    @Test
    fun raggedBuffersMatchOneContinuousRender() {
        val signal = Signals.speech(2.0, 48_000.0)
        val processor = engine(enabled = true).createAudioProcessors().single()
        processor.start(AudioFormat(48_000, 1, C.ENCODING_PCM_FLOAT))
        val output = ByteBuffer.wrap(processor.run(floats(signal), 4)).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
        val rendered = FloatArray(output.remaining()).also { output.get(it) }

        val reference = NoiseReductionProcessor().apply {
            configure(NoiseReductionMode.CADENCE, 0.5f, 0.7f, 12f, VoiceFocusPreset.LIFT)
            prepare(1, signal.size, 48_000.0)
        }
        val expected = signal.copyOf().also { Buffers.processMono(reference, it) }
        assertThat(rendered.size).isEqualTo(signal.size)
        assertThat(Signals.maxDifference(rendered, expected)).isLessThan(0.00001f)
        assertThat(Signals.maxDifference(rendered, signal)).isGreaterThan(0.001f)
    }

    @Test
    fun boostedSixteenBitOutputNeverWraps() {
        val signal = Signals.speech(2.0, 22_050.0)
        val processor = engine(enabled = true, boost = 4.0).createAudioProcessors().single()
        processor.start(AudioFormat(22_050, 1, C.ENCODING_PCM_16BIT))
        val output = shorts(processor.run(pcm16(signal), 2))
        val peak = output.maxOf { kotlin.math.abs(it.toInt()) } / 32768f
        assertThat(peak).isAtMost(0.97f)
        assertThat(Signals.rms(FloatArray(output.size) { output[it] / 32768f })).isGreaterThan(Signals.rms(signal) * 1.4f)
    }

    @Test
    fun unsupportedEncodingIsInactiveAndReported() {
        val engine = engine(enabled = true)
        engine.onPlaybackChanged(hasTrack = true, isPlaying = true)
        val processor = engine.createAudioProcessors().single()
        assertThat(processor.configure(AudioFormat(44_100, 2, C.ENCODING_PCM_24BIT))).isEqualTo(AudioFormat.NOT_SET)
        assertThat(processor.isActive).isFalse()
        engine.refresh()
        assertThat(engine.status.value).isEqualTo(AudioProcessingStatus.UnsupportedFormat)
    }

    @Test
    fun flushResetsHistoryWithoutAnotherPreparation() {
        val engine = engine(enabled = true)
        val processor = engine.createAudioProcessors().single() as NoiseReductionAudioProcessor
        processor.start(AudioFormat(22_050, 1, C.ENCODING_PCM_16BIT))
        processor.run(pcm16(Signals.speech(0.5, 22_050.0)), 2)
        processor.flush(AudioProcessor.StreamMetadata.DEFAULT)
        val silence = shorts(processor.run(ByteArray(4096), 2))
        assertThat(silence.all { it.toInt() == 0 }).isTrue()
        assertThat(engine.createAudioProcessors().single().let { (it as NoiseReductionAudioProcessor).generation })
            .isEqualTo(processor.generation + 1)
    }

    @Test
    fun resetUnpreparesUntilTheNextFormat() {
        val processor = engine(enabled = true).createAudioProcessors().single()
        processor.start(AudioFormat(22_050, 1, C.ENCODING_PCM_16BIT))
        processor.reset()
        processor.start(AudioFormat(44_100, 2, C.ENCODING_PCM_16BIT))
        val input = pcm16(interleave(Signals.speech(0.5, 44_100.0), Signals.speech(0.5, 44_100.0)))
        val output = processor.run(input, 4)
        assertThat(output.size).isEqualTo(input.size)
        assertThat(output.toList()).isNotEqualTo(input.toList())
    }
}
