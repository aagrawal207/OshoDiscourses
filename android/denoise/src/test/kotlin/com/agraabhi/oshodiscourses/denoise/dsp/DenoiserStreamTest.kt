package com.agraabhi.oshodiscourses.denoise.dsp

import com.google.common.truth.Truth.assertThat
import com.google.common.truth.Truth.assertWithMessage
import org.junit.Test

class DenoiserStreamTest {
    private fun copyHop(stream: DenoiserStream) = HopTransform { input, offset, output ->
        System.arraycopy(input, offset, output, 0, stream.hopSize)
        true
    }

    private fun run(stream: DenoiserStream, samples: FloatArray): Boolean =
        stream.process(samples, 0, samples.size, copyHop(stream))

    @Test
    fun raggedCallbacksMatchOneContinuousStream() {
        for (rate in intArrayOf(8_000, 16_000, 22_050, 32_000, 44_100, 48_000, 96_000, 192_000)) {
            val input = Signals.sine(371.0, rate.toDouble(), rate / 2, amplitude = 0.25)
            val whole = input.copyOf()
            assertThat(run(DenoiserStream(rate.toDouble(), input.size, 480), whole)).isTrue()

            val raggedStream = DenoiserStream(rate.toDouble(), 1024, 480)
            val ragged = FloatArray(input.size)
            val sizes = intArrayOf(1, 37, 1024, 480, 999, 7)
            var done = 0
            var index = 0
            while (done < input.size) {
                val end = minOf(input.size, done + sizes[index % sizes.size])
                val block = input.copyOfRange(done, end)
                assertWithMessage("FIFO must not underflow at $rate Hz").that(run(raggedStream, block)).isTrue()
                block.copyInto(ragged, done)
                done = end
                index += 1
            }
            assertWithMessage("block shape changed audio at $rate Hz")
                .that(Signals.maxDifference(whole, ragged)).isLessThan(0.00001f)
        }
    }

    @Test
    fun failedHopLeavesCallerAudioUntouchedAndResetRecovers() {
        val stream = DenoiserStream(48_000.0, 1024, 480)
        val input = FloatArray(1024) { 0.25f }
        assertThat(stream.process(input, 0, input.size) { _, _, _ -> false }).isFalse()
        assertThat(input.all { it == 0.25f }).isTrue()
        stream.reset()
        assertThat(run(stream, input)).isTrue()
        assertThat(input.take(stream.primeCount).all { it == 0f }).isTrue()
        assertThat(input.drop(stream.primeCount).all { it == 0.25f }).isTrue()
    }

    @Test
    fun oversizedCallbackDoesNotConsumeStreamState() {
        val stream = DenoiserStream(48_000.0, 480, 480)
        val oversized = FloatArray(481) { 0.9f }
        assertThat(run(stream, oversized)).isFalse()
        assertThat(oversized.all { it == 0.9f }).isTrue()
        val first = FloatArray(480) { 0.1f }
        val second = FloatArray(480) { 0.2f }
        assertThat(run(stream, first)).isTrue()
        assertThat(run(stream, second)).isTrue()
        assertThat(first.all { it == 0f }).isTrue()
        assertThat(second.all { it == 0.1f }).isTrue()
    }

    @Test
    fun processesAtAnOffsetWithoutTouchingTheRestOfTheArray() {
        val stream = DenoiserStream(48_000.0, 480, 480)
        val samples = FloatArray(960) { 0.3f }
        assertThat(stream.process(samples, 480, 480, copyHop(stream))).isTrue()
        assertThat(samples.take(480).all { it == 0.3f }).isTrue()
        assertThat(samples.drop(480).all { it == 0f }).isTrue()
    }
}
