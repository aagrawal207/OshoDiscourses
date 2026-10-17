package com.agraabhi.oshodiscourses.denoise.dsp

import com.agraabhi.oshodiscourses.core.model.NoiseReductionMode
import com.agraabhi.oshodiscourses.core.model.VoiceFocusPreset
import com.google.common.truth.Truth.assertThat
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread
import org.junit.Test

/** The status poll runs beside the render thread for the whole talk, so it must never disturb it. */
class DiagnosticsPollingTest {
    @Test
    fun snapshotsDuringRenderingNeverSkipABufferOrRequestAReset() {
        val stream = NoiseReductionStream(tapGeneration = 1).apply {
            configure(NoiseReductionMode.CADENCE, 0.5f, 0.7f, 12f, VoiceFocusPreset.FOCUS)
            prepare(2, 1024, 22_050.0)
        }
        val block = Buffers.Block(2, 1024, interleaved = true).apply { fill() }
        val done = AtomicBoolean(false)
        val render = thread(name = "render") {
            repeat(CHUNKS) { index ->
                block.fill(index * 1024)
                stream.process(block.buffers, block.lanes, block.frames)
            }
            done.set(true)
        }
        var snapshots = 0
        while (!done.get()) {
            stream.diagnosticsSnapshot()
            snapshots += 1
        }
        render.join()

        val diagnostics = stream.diagnosticsSnapshot()
        assertThat(snapshots).isGreaterThan(0)
        assertThat(diagnostics.lockContendedBuffers).isEqualTo(0)
        assertThat(diagnostics.resetRequests).isEqualTo(0)
        assertThat(diagnostics.resetPending).isFalse()
        assertThat(diagnostics.streamResets).isEqualTo(0)
        assertThat(diagnostics.modelBypassedBuffers).isEqualTo(0)
        assertThat(diagnostics.processedBuffers).isEqualTo(CHUNKS.toLong())
    }

    private companion object {
        const val CHUNKS = 20_000
    }
}
