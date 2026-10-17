package com.agraabhi.oshodiscourses.denoise.dsp

import com.google.common.truth.Truth.assertThat
import com.google.common.truth.Truth.assertWithMessage
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.log10
import kotlin.math.sin
import kotlin.math.sqrt
import org.junit.Test

/** The resampler lets the 48 kHz models run on the 22,050 Hz archive at all. */
class PolyphaseResamplerTest {
    private fun run(resampler: PolyphaseResampler, input: FloatArray, output: FloatArray): Int =
        resampler.process(input, 0, input.size, output, 0, output.size)

    @Test
    fun reducesRatioToLowestTerms() {
        val up = PolyphaseResampler(22_050, 48_000, 1024)
        assertThat(up.interpolation).isEqualTo(320)
        assertThat(up.decimation).isEqualTo(147)
        val down = PolyphaseResampler(48_000, 22_050, 1024)
        assertThat(down.interpolation).isEqualTo(147)
        assertThat(down.decimation).isEqualTo(320)
        val same = PolyphaseResampler(48_000, 48_000, 128)
        assertThat(same.interpolation).isEqualTo(1)
        assertThat(same.decimation).isEqualTo(1)
    }

    @Test
    fun producesRoughlyTheExpectedSampleCount() {
        val resampler = PolyphaseResampler(22_050, 48_000, 2048)
        val produced = run(resampler, FloatArray(2048), FloatArray(8192))
        assertThat(abs(produced - 2048.0 * 48_000 / 22_050)).isLessThan(3.0)
    }

    @Test
    fun preservesLevelOfAConstantSignal() {
        val resampler = PolyphaseResampler(22_050, 48_000, 1024)
        val input = FloatArray(1024) { 0.5f }
        val output = FloatArray(4096)
        run(resampler, input, output)
        val produced = run(resampler, input, output)
        val steady = output.copyOfRange(100, produced)
        assertWithMessage("DC gain drifted").that(abs(steady.average() - 0.5)).isLessThan(0.01)
        assertWithMessage("phases must not modulate DC").that(steady.all { abs(it - 0.5f) < 0.00001f }).isTrue()
    }

    @Test
    fun preservesAToneAtTheCorrectFrequency() {
        val resampler = PolyphaseResampler(22_050, 48_000, 4096)
        val input = Signals.sine(300.0, 22_050.0, 4096)
        val output = FloatArray(12_000)
        run(resampler, input, output)
        val produced = run(resampler, input, output)
        val steady = output.copyOfRange(200, produced - 10)
        assertThat(abs(Signals.rms(steady) - (0.5 / sqrt(2.0)).toFloat())).isLessThan(0.02f)
        var crossings = 0
        for (index in 1 until steady.size) if (steady[index - 1] < 0 && steady[index] >= 0) crossings += 1
        val measured = crossings / (steady.size / 48_000.0)
        assertWithMessage("frequency shifted to $measured Hz").that(abs(measured - 300)).isLessThan(6.0)
    }

    @Test
    fun suppressesContentAboveTheOutputNyquist() {
        for (frequency in doubleArrayOf(11_025.0, 12_000.0, 14_000.0, 18_000.0)) {
            val resampler = PolyphaseResampler(48_000, 22_050, 48_000)
            val input = Signals.sine(frequency, 48_000.0, 48_000)
            val output = FloatArray(25_000)
            val produced = run(resampler, input, output)
            val rms = Signals.rms(output, 1000, produced)
            assertWithMessage("less than 80 dB rejection at $frequency Hz").that(rms).isLessThan(0.0000354f)
        }
    }

    @Test
    fun preservesTheConsonantBand() {
        for (frequency in doubleArrayOf(300.0, 3_000.0, 8_000.0, 9_500.0)) {
            val input = Signals.sine(frequency, 22_050.0, 22_050)
            val up = PolyphaseResampler(22_050, 48_000, input.size)
            val down = PolyphaseResampler(48_000, 22_050, 50_000)
            val mid = FloatArray(50_000)
            val out = FloatArray(25_000)
            val midCount = run(up, input, mid)
            val count = down.process(mid, 0, midCount, out, 0, out.size)
            val gainDb = 20 * log10(Signals.rms(out, 1000, count) / (0.5 / sqrt(2.0)).toFloat())
            assertWithMessage("round-trip gain at $frequency Hz").that(abs(gainDb)).isLessThan(0.1f)
        }
    }

    @Test
    fun shortDestinationDoesNotAdvanceHistory() {
        val resampler = PolyphaseResampler(22_050, 48_000, 512)
        val reference = PolyphaseResampler(22_050, 48_000, 512)
        val input = FloatArray(512) { sin(it * 0.07).toFloat() }
        val short = floatArrayOf(-1f)
        assertThat(run(resampler, input, short)).isEqualTo(0)
        assertThat(short.toList()).containsExactly(-1f)
        val actual = FloatArray(2048)
        val expected = FloatArray(2048)
        val count = run(resampler, input, actual)
        assertThat(count).isEqualTo(run(reference, input, expected))
        assertThat(actual.toList()).isEqualTo(expected.toList())
    }

    @Test
    fun roundTripThroughTheModelRateStaysRecognisable() {
        val up = PolyphaseResampler(22_050, 48_000, 4096)
        val down = PolyphaseResampler(48_000, 22_050, 12_000)
        val input = FloatArray(4096) { index ->
            val t = index / 22_050.0
            (0.3 * sin(2 * PI * 220 * t) + 0.15 * sin(2 * PI * 700 * t)).toFloat()
        }
        val mid = FloatArray(12_000)
        val out = FloatArray(12_000)
        repeat(2) {
            val m = run(up, input, mid)
            down.process(mid, 0, m, out, 0, out.size)
        }
        val midCount = run(up, input, mid)
        val produced = down.process(mid, 0, midCount, out, 0, out.size)
        val change = 20 * log10(Signals.rms(out, 100, produced - 10) / Signals.rms(input))
        assertWithMessage("round trip changed level by $change dB").that(abs(change)).isLessThan(0.5f)
    }

    @Test
    fun passesThroughUnchangedWhenRatesMatch() {
        val resampler = PolyphaseResampler(48_000, 48_000, 512)
        val input = FloatArray(512) { sin(it * 0.05).toFloat() * 0.4f }
        val output = FloatArray(1024)
        run(resampler, input, output)
        val produced = run(resampler, input, output)
        assertThat(produced).isEqualTo(512)
        assertThat(output.copyOf(produced).toList()).isEqualTo(input.toList())
    }

    @Test
    fun resetClearsFilterMemory() {
        val resampler = PolyphaseResampler(22_050, 48_000, 512)
        val output = FloatArray(2048)
        run(resampler, FloatArray(512) { 0.9f }, output)
        resampler.reset()
        val produced = run(resampler, FloatArray(512), output)
        assertThat(output.copyOf(produced).all { abs(it) < 1e-6f }).isTrue()
    }

    @Test
    fun neverExceedsTheReportedOutputBound() {
        val resampler = PolyphaseResampler(22_050, 48_000, 1024)
        val bound = resampler.maximumOutputCount(1024)
        val output = FloatArray(bound)
        val input = FloatArray(1024) { 0.1f }
        repeat(20) { assertThat(resampler.process(input, 0, input.size, output, 0, bound)).isAtMost(bound) }
    }
}
