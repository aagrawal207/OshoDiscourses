package com.agraabhi.oshodiscourses.denoise.dsp

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.agraabhi.oshodiscourses.core.model.NoiseReductionMode
import com.agraabhi.oshodiscourses.core.model.VoiceFocusPreset
import com.google.common.truth.Truth.assertThat
import com.google.common.truth.Truth.assertWithMessage
import kotlin.math.abs
import org.junit.Test
import org.junit.runner.RunWith

/** Neural-mode boundaries, read failures and resets (iOS `NoiseDiscontinuityTests`). */
@RunWith(AndroidJUnit4::class)
class NoiseDiscontinuityNativeTest {
    private val neural = listOf(NoiseReductionMode.RNNOISE, NoiseReductionMode.DEEP_FILTER_NET)
    private val read = SourceRead()

    private fun source(block: Buffers.Block, processor: NoiseReductionProcessor, startOfStream: Boolean = false, status: Int = 0): SourceRead {
        processor.processSourceAudio(block.buffers, block.lanes, read.set(block.frames, block.frames, startOfStream, status))
        return read
    }

    @Test
    fun firstStartFlagDoesNotAddAResetOrBypass() {
        for (mode in neural) {
            val processor = NativeFixtures.ready(mode)
            val reference = NativeFixtures.ready(mode)
            val actual = Buffers.Block(1, 1024, false).apply { fill() }
            val expected = Buffers.Block(1, 1024, false).apply { fill() }
            assertThat(source(actual, processor, startOfStream = true).startOfStream).isTrue()
            source(expected, reference)
            assertThat(Signals.maxDifference(actual.contents(), expected.contents())).isLessThan(0.00001f)
            val diagnostics = processor.diagnosticsSnapshot()
            assertThat(diagnostics.sourceDiscontinuities).isEqualTo(1)
            assertThat(diagnostics.streamResets).isEqualTo(0)
            assertWithMessage("$mode").that(diagnostics.processedBuffers).isEqualTo(1)
            assertThat(diagnostics.resetBypassedBuffers).isEqualTo(0)
        }
    }

    @Test
    fun sourceBoundaryDiscardsAllPreviousChannelAudio() {
        for (mode in neural) for (interleaved in listOf(false, true)) {
            val processor = NativeFixtures.ready(mode, channels = 2)
            val block = Buffers.Block(2, 1024, interleaved)
            for (index in 0 until 20) {
                block.fill(index * 1024)
                source(block, processor)
            }
            block.fill(silent = true)
            source(block, processor, startOfStream = true)
            assertWithMessage("$mode must not emit an old FIFO").that(block.contents().all { it == 0f }).isTrue()
            awaitReset(processor)
            repeat(10) {
                block.fill(silent = true)
                source(block, processor)
                assertWithMessage("$mode interleaved=$interleaved").that(block.contents().all { it.isFinite() && abs(it) < 0.0001f }).isTrue()
            }
            val diagnostics = processor.diagnosticsSnapshot()
            assertThat(diagnostics.streamResets).isEqualTo(1)
            assertThat(diagnostics.resetBypassedBuffers).isEqualTo(1)
        }
    }

    @Test
    fun failedSourceReadReturnsNoAudioAndRecoveryDiscardsHistory() {
        for (mode in neural) {
            val processor = NativeFixtures.ready(mode, channels = 2)
            val block = Buffers.Block(2, 1024, interleaved = true)
            for (index in 0 until 12) {
                block.fill(index * 1024)
                source(block, processor)
            }
            block.fill(20_000)
            val original = block.contents()
            assertThat(source(block, processor, startOfStream = true, status = -50).returnedFrames).isEqualTo(0)
            assertThat(block.contents().toList()).isEqualTo(original.toList())
            awaitReset(processor)
            repeat(8) {
                block.fill(silent = true)
                source(block, processor)
                assertWithMessage("$mode").that(block.contents().all { abs(it) < 0.0001f }).isTrue()
            }
            assertThat(processor.diagnosticsSnapshot().streamResets).isEqualTo(1)
        }
    }

    @Test
    fun repeatedEmptyStartBoundariesKeepLatencyBounded() {
        for (mode in neural) {
            val processor = NativeFixtures.ready(mode, maxFrames = 4096)
            val signal = Signals.syllables(2.0, 22_050.0)
            val boundary = Buffers.Block(1, 0, interleaved = false)
            var firstLag = 0
            for (iteration in 0..12) {
                if (iteration > 0) {
                    processor.processSourceAudio(boundary.buffers, boundary.lanes, read.set(1024, 0, startOfStream = true))
                    awaitReset(processor)
                }
                val lag = Signals.bestLag(signal, Buffers.render(processor, signal), 2205)
                if (iteration == 0) firstLag = lag
                assertWithMessage("$mode latency after $iteration boundaries").that(abs(lag - firstLag)).isAtMost(1)
                assertThat(lag).isIn(1..2204)
            }
            assertThat(processor.diagnosticsSnapshot().streamResets).isEqualTo(12)
        }
    }

    @Test
    fun laterChannelFailureLeavesTheEntireBufferRaw() {
        for (interleaved in listOf(false, true)) {
            val processor = NoiseReductionProcessor(rnnoiseFactory = { rate, frames, channel ->
                RNNoiseProcessor.create(rate, if (channel == 0) frames else 480)
            })
            processor.configure(NoiseReductionMode.RNNOISE, 0.5f, 0.7f, 12f, VoiceFocusPreset.FOCUS, outputGain = 4f)
            processor.prepare(2, 1024, 22_050.0)
            val failed = Buffers.Block(2, 1024, interleaved).apply { fill() }
            val original = failed.contents()
            source(failed, processor)
            assertWithMessage("no partial denoising or boost may escape").that(failed.contents().toList()).isEqualTo(original.toList())
            awaitReset(processor)
            assertThat(processor.diagnosticsSnapshot().modelBypassedBuffers).isEqualTo(1)
            assertThat(processor.diagnosticsSnapshot().processedBuffers).isEqualTo(0)

            val reference = NativeFixtures.ready(NoiseReductionMode.RNNOISE, channels = 2, gain = 4f)
            val actual = Buffers.Block(2, 480, interleaved)
            val expected = Buffers.Block(2, 480, interleaved)
            for (index in 0 until 12) {
                actual.fill(index * 480)
                expected.fill(index * 480)
                source(actual, processor)
                source(expected, reference)
                assertThat(Signals.maxDifference(actual.contents(), expected.contents())).isLessThan(0.00001f)
                assertThat(actual.contents().all { it.isFinite() && abs(it) <= 1f }).isTrue()
            }
        }
    }
}
