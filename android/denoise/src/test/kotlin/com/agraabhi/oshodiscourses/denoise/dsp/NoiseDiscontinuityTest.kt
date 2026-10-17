package com.agraabhi.oshodiscourses.denoise.dsp

import com.agraabhi.oshodiscourses.core.model.NoiseReductionMode
import com.agraabhi.oshodiscourses.core.model.VoiceFocusPreset
import com.google.common.truth.Truth.assertThat
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread
import kotlin.math.abs
import org.junit.Test

/** Gentle Cleanup and lock cases of the iOS `NoiseDiscontinuityTests`; native modes are instrumented. */
class NoiseDiscontinuityTest {
    private val read = SourceRead()

    private fun ready(mode: NoiseReductionMode, channels: Int = 1, maxFrames: Int = 1024): NoiseReductionProcessor =
        NoiseReductionProcessor().apply {
            configure(mode, 0.5f, 0.7f, 12f, VoiceFocusPreset.FOCUS)
            prepare(channels, maxFrames, 22_050.0)
        }

    private fun source(
        block: Buffers.Block,
        processor: NoiseReductionProcessor,
        startOfStream: Boolean = false,
        status: Int = 0,
        returnedFrames: Int = block.frames,
    ): SourceRead {
        processor.processSourceAudio(block.buffers, block.lanes, read.set(block.frames, returnedFrames, startOfStream, status))
        return read
    }

    @Test
    fun firstStartFlagDoesNotAddAResetOrBypass() {
        val processor = ready(NoiseReductionMode.CADENCE)
        val reference = ready(NoiseReductionMode.CADENCE)
        val actual = Buffers.Block(1, 1024, interleaved = false).apply { fill() }
        val expected = Buffers.Block(1, 1024, interleaved = false).apply { fill() }
        val result = source(actual, processor, startOfStream = true)
        assertThat(result.returnedFrames).isEqualTo(1024)
        assertThat(result.startOfStream).isTrue()
        source(expected, reference)
        assertThat(Signals.maxDifference(actual.contents(), expected.contents())).isLessThan(0.00001f)
        val diagnostics = processor.diagnosticsSnapshot()
        assertThat(diagnostics.sourceDiscontinuities).isEqualTo(1)
        assertThat(diagnostics.streamResets).isEqualTo(0)
        assertThat(diagnostics.processedBuffers).isEqualTo(1)
        assertThat(diagnostics.resetBypassedBuffers).isEqualTo(0)
        assertThat(diagnostics.resetPending).isFalse()
    }

    @Test
    fun sourceBoundaryDiscardsAllPreviousChannelAudio() {
        for (interleaved in listOf(false, true)) {
            val processor = ready(NoiseReductionMode.CADENCE, channels = 2)
            val block = Buffers.Block(2, 1024, interleaved)
            for (index in 0 until 20) {
                block.fill(index * 1024)
                source(block, processor)
            }
            block.fill(silent = true)
            assertThat(source(block, processor, startOfStream = true).returnedFrames).isEqualTo(1024)
            assertThat(block.contents().all { it == 0f }).isTrue()
            awaitReset(processor)
            repeat(10) {
                block.fill(silent = true)
                source(block, processor)
                assertThat(block.contents().all { it.isFinite() && abs(it) < 0.0001f }).isTrue()
            }
            val diagnostics = processor.diagnosticsSnapshot()
            assertThat(diagnostics.sourceDiscontinuities).isEqualTo(1)
            assertThat(diagnostics.streamResets).isEqualTo(1)
            assertThat(diagnostics.resetBypassedBuffers).isEqualTo(1)
        }
    }

    @Test
    fun failedSourceReadReturnsNoAudioAndRecoveryDiscardsHistory() {
        val processor = ready(NoiseReductionMode.CADENCE, channels = 2)
        val block = Buffers.Block(2, 1024, interleaved = true)
        for (index in 0 until 12) {
            block.fill(index * 1024)
            source(block, processor)
        }
        block.fill(20_000)
        val original = block.contents()
        val failed = source(block, processor, startOfStream = true, status = -50)
        assertThat(failed.returnedFrames).isEqualTo(0)
        assertThat(failed.startOfStream).isFalse()
        assertThat(block.contents().toList()).isEqualTo(original.toList())
        awaitReset(processor)
        var diagnostics = processor.diagnosticsSnapshot()
        assertThat(diagnostics.sourceReadFailures).isEqualTo(1)
        assertThat(diagnostics.sourceReadFailed).isTrue()
        assertThat(diagnostics.sourceDiscontinuities).isEqualTo(0)
        repeat(8) {
            block.fill(silent = true)
            source(block, processor)
            assertThat(block.contents().all { abs(it) < 0.0001f }).isTrue()
        }
        diagnostics = processor.diagnosticsSnapshot()
        assertThat(diagnostics.sourceReadFailed).isFalse()
        assertThat(diagnostics.streamResets).isEqualTo(1)
    }

    @Test
    fun malformedSuccessfulReadCannotExposeOldBufferMemory() {
        val processor = ready(NoiseReductionMode.CADENCE)
        val block = Buffers.Block(1, 1024, interleaved = false).apply { fill() }
        val original = block.contents()
        for (count in intArrayOf(-1, 1025)) {
            val result = source(block, processor, returnedFrames = count)
            assertThat(result.returnedFrames).isEqualTo(0)
            assertThat(result.startOfStream).isFalse()
            assertThat(block.contents().toList()).isEqualTo(original.toList())
        }
        assertThat(processor.diagnosticsSnapshot().sourceReadFailures).isEqualTo(2)
    }

    @Test
    fun sourceBoundaryNeverWaitsForTheControlLock() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val prepared = CountDownLatch(1)
        val rendered = CountDownLatch(1)
        val raw = AtomicBoolean(false)
        val processor = NoiseReductionProcessor(rnnoiseFactory = { _, _, _ ->
            entered.countDown()
            release.await()
            null
        })
        thread {
            processor.prepare(1, 1024, 22_050.0)
            prepared.countDown()
        }
        assertThat(entered.await(5, TimeUnit.SECONDS)).isTrue()
        thread {
            val samples = FloatArray(1024) { 0.25f }
            processor.process(arrayOf(samples), Buffers.MONO, 1024, startOfStream = true)
            raw.set(samples.all { it == 0.25f })
            rendered.countDown()
        }
        val completedWithoutControlLock = rendered.await(500, TimeUnit.MILLISECONDS)
        release.countDown()
        assertThat(prepared.await(5, TimeUnit.SECONDS)).isTrue()
        assertThat(completedWithoutControlLock).isTrue()
        assertThat(raw.get()).isTrue()
        assertThat(processor.diagnosticsSnapshot().lockContendedBuffers).isEqualTo(1)
    }

    @Test
    fun aCallerOwnedBoundaryResetsAtOnceInsteadOfBypassing() {
        val processor = NoiseReductionProcessor()
        processor.configure(NoiseReductionMode.CADENCE, 0.5f, 0.7f, 12f, VoiceFocusPreset.FOCUS)
        val context = checkNotNull(processor.makeTapContext(1))
        context.prepare(1, 1024, 22_050.0)
        val block = Buffers.Block(1, 1024, interleaved = false)
        repeat(5) {
            block.fill(it * 1024)
            context.processSourceAudio(block.buffers, block.lanes, read.set(1024))
        }
        context.resetAtBoundary()
        block.fill(silent = true)
        assertThat(context.processSourceAudio(block.buffers, block.lanes, read.set(1024))).isTrue()
        val diagnostics = processor.diagnosticsSnapshot()
        assertThat(diagnostics.streamResets).isEqualTo(1)
        assertThat(diagnostics.resetBypassedBuffers).isEqualTo(0)
        assertThat(diagnostics.resetPending).isFalse()
    }
}
