package com.agraabhi.oshodiscourses.denoise.dsp

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.agraabhi.oshodiscourses.core.domain.player.DeepFilterStatus
import com.agraabhi.oshodiscourses.core.model.NoiseReductionMode
import com.agraabhi.oshodiscourses.core.model.VoiceFocusPreset
import com.agraabhi.oshodiscourses.denoise.dsp.NativeFixtures.process
import com.agraabhi.oshodiscourses.denoise.dsp.NativeFixtures.waitForActive
import com.agraabhi.oshodiscourses.denoise.nativebridge.DeepFilterNative
import com.agraabhi.oshodiscourses.denoise.nativebridge.NativeDenoisers
import com.google.common.truth.Truth.assertThat
import com.google.common.truth.Truth.assertWithMessage
import java.io.File
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** The real bundled model through the Rust bridge (iOS `DeepFilterNetTests`). */
@RunWith(AndroidJUnit4::class)
class DeepFilterNetTest {
    @Before
    fun loadNative() {
        assertThat(NativeDenoisers.isAvailable).isTrue()
    }

    private fun sum(samples: FloatArray) = samples.fold(0f) { total, value -> total + value * value }

    @Test
    fun modelIsBundledWithTheApp() {
        assertWithMessage("a few KB would mean a truncated model").that(File(NativeFixtures.modelPath).length()).isGreaterThan(1_000_000L)
    }

    @Test
    fun bridgeReportsDeepFilterNet3Geometry() {
        val handle = DeepFilterNative.create(NativeFixtures.modelPath, 100f)
        assertThat(handle).isNotEqualTo(0L)
        try {
            assertThat(DeepFilterNative.hopSize(handle)).isEqualTo(480)
            assertThat(DeepFilterNative.sampleRate(handle)).isEqualTo(48_000)
        } finally {
            DeepFilterNative.destroy(handle)
        }
    }

    @Test
    fun bridgeRejectsWrongFrameLength() {
        val handle = DeepFilterNative.create(NativeFixtures.modelPath, 100f)
        try {
            val status = DeepFilterNative.processFrame(handle, FloatArray(128), 0, FloatArray(128), 128, null)
            assertThat(status).isEqualTo(DeepFilterNative.ERR_ARG)
        } finally {
            DeepFilterNative.destroy(handle)
        }
    }

    @Test
    fun bridgeSurvivesNullAndBadInput() {
        assertThat(DeepFilterNative.hopSize(0)).isEqualTo(0)
        assertThat(DeepFilterNative.sampleRate(0)).isEqualTo(0)
        assertThat(DeepFilterNative.setAttenuationLimit(0, 20f)).isEqualTo(DeepFilterNative.ERR_NULL)
        assertThat(DeepFilterNative.setPostFilterBeta(0, 0.02f)).isEqualTo(DeepFilterNative.ERR_NULL)
        assertThat(DeepFilterNative.reset(0)).isEqualTo(DeepFilterNative.ERR_NULL)
        assertThat(DeepFilterNative.processFrame(0, null, 0, null, 480, null)).isEqualTo(DeepFilterNative.ERR_NULL)
        DeepFilterNative.destroy(0)
        assertThat(DeepFilterNative.create("/nonexistent/model.tar.gz", 100f)).isEqualTo(0L)
    }

    @Test
    fun bridgeAcceptsAttenuationAndResetChanges() {
        val handle = DeepFilterNative.create(NativeFixtures.modelPath, 100f)
        try {
            assertThat(DeepFilterNative.setAttenuationLimit(handle, 12f)).isEqualTo(DeepFilterNative.OK)
            assertThat(DeepFilterNative.setPostFilterBeta(handle, 0.02f)).isEqualTo(DeepFilterNative.OK)
            assertThat(DeepFilterNative.reset(handle)).isEqualTo(DeepFilterNative.OK)
            assertThat(DeepFilterNative.setAttenuationLimit(handle, -1f)).isEqualTo(DeepFilterNative.ERR_ARG)
            assertThat(DeepFilterNative.setAttenuationLimit(handle, Float.NaN)).isEqualTo(DeepFilterNative.ERR_ARG)
        } finally {
            DeepFilterNative.destroy(handle)
        }
    }

    @Test
    fun modelAttenuatesBroadbandNoise() {
        val handle = DeepFilterNative.create(NativeFixtures.modelPath, 100f)
        try {
            val generator = SplitMix64(0x0570_1234)
            val output = FloatArray(480)
            var inputEnergy = 0f
            var outputEnergy = 0f
            for (frame in 0 until 100) {
                val input = FloatArray(480) { generator.nextUniform() * 0.3f }
                assertThat(DeepFilterNative.processFrame(handle, input, 0, output, 480, null)).isEqualTo(DeepFilterNative.OK)
                if (frame <= 50) continue
                inputEnergy += sum(input)
                outputEnergy += sum(output)
            }
            assertThat(outputEnergy).isLessThan(inputEnergy * 0.5f)
        } finally {
            DeepFilterNative.destroy(handle)
        }
    }

    @Test
    fun processorRefusesOnlyImplausibleSampleRates() {
        val processor = NativeFixtures.deepFilter()
        processor.activate(1, 1024, 1_000.0)
        assertThat(processor.currentStatus).isEqualTo(DeepFilterStatus.UnsupportedSampleRate(1_000.0))
        assertThat(processor.currentStatus.isBypassing).isTrue()
        val samples = floatArrayOf(0.25f, -0.5f, 0.75f, -1f)
        assertThat(process(processor, samples)).isFalse()
        assertThat(samples.toList()).containsExactly(0.25f, -0.5f, 0.75f, -1f).inOrder()
    }

    @Test
    fun unsupportedFormatWinsOverAnOlderInFlightLoad() {
        val processor = NativeFixtures.deepFilter()
        processor.activate(1, 1024, 48_000.0)
        processor.activate(1, 1024, 1_000.0)
        assertThat(processor.currentStatus).isEqualTo(DeepFilterStatus.UnsupportedSampleRate(1_000.0))
        Thread.sleep(2_000)
        assertThat(processor.currentStatus).isEqualTo(DeepFilterStatus.UnsupportedSampleRate(1_000.0))
        val samples = FloatArray(480) { 0.25f }
        assertThat(process(processor, samples)).isFalse()
        assertThat(samples.all { it == 0.25f }).isTrue()
    }

    @Test
    fun processorRunsOn22kHzCatalogAudioByResampling() {
        val processor = NativeFixtures.deepFilter()
        processor.activate(1, 4096, 22_050.0)
        waitForActive(processor)
        val generator = SplitMix64(4242)
        var inputEnergy = 0f
        var outputEnergy = 0f
        for (index in 0 until 80) {
            val buffer = FloatArray(1024) { generator.nextUniform() * 0.3f }
            val before = sum(buffer)
            assertWithMessage("22.05 kHz audio must be processed").that(process(processor, buffer)).isTrue()
            assertThat(buffer.all { it.isFinite() }).isTrue()
            if (index <= 30) continue
            inputEnergy += before
            outputEnergy += sum(buffer)
        }
        assertThat(outputEnergy).isLessThan(inputEnergy * 0.6f)
    }

    @Test
    fun processorBecomesActiveAndDenoises() {
        val processor = NativeFixtures.deepFilter()
        processor.activate(1, 4096, 48_000.0)
        waitForActive(processor)
        val generator = SplitMix64(99)
        var inputEnergy = 0f
        var outputEnergy = 0f
        for (index in 0 until 60) {
            val buffer = FloatArray(1024) { generator.nextUniform() * 0.3f }
            val before = sum(buffer)
            assertThat(process(processor, buffer)).isTrue()
            if (index <= 20) continue
            inputEnergy += before
            outputEnergy += sum(buffer)
        }
        assertThat(outputEnergy).isLessThan(inputEnergy * 0.5f)
    }

    @Test
    fun processorPreservesBufferLengthAndStaysFinite() {
        val processor = NativeFixtures.deepFilter()
        processor.activate(1, 2048, 48_000.0)
        waitForActive(processor)
        for (count in intArrayOf(480, 1024, 37, 999, 2048, 1)) {
            val buffer = FloatArray(count) { 0.1f }
            assertThat(process(processor, buffer)).isTrue()
            assertThat(buffer.all { it.isFinite() }).isTrue()
        }
    }

    @Test
    fun processorIgnoresChannelsItHasNoModelFor() {
        val processor = NativeFixtures.deepFilter()
        processor.activate(1, 1024, 48_000.0)
        waitForActive(processor)
        val samples = FloatArray(480) { 0.4f }
        assertThat(process(processor, samples, channel = 1)).isFalse()
        assertThat(samples.all { it == 0.4f }).isTrue()
    }

    @Test
    fun processorLoadsOneModelPerChannelForStereo() {
        val processor = NativeFixtures.deepFilter()
        processor.activate(2, 1024, 48_000.0)
        waitForActive(processor)
        for (channel in 0 until 2) {
            val buffer = FloatArray(960) { 0.25f }
            assertWithMessage("channel $channel").that(process(processor, buffer, channel)).isTrue()
        }
    }

    @Test
    fun growingFromMonoToStereoAddsOnlyTheMissingChannel() {
        val processor = NativeFixtures.deepFilter()
        processor.activate(1, 1024, 48_000.0)
        waitForActive(processor)
        processor.activate(2, 1024, 48_000.0)
        waitForActive(processor)
        for (channel in 0 until 2) assertThat(process(processor, FloatArray(480) { 0.2f }, channel)).isTrue()
        val extra = FloatArray(480) { 0.2f }
        assertThat(process(processor, extra, channel = 2)).isFalse()
        assertThat(extra.all { it == 0.2f }).isTrue()
    }

    @Test
    fun resetAndAttenuationChangesDoNotBreakProcessing() {
        val processor = NativeFixtures.deepFilter()
        processor.activate(1, 1024, 48_000.0)
        waitForActive(processor)
        processor.reset()
        processor.setAttenuationLimit(6f)
        assertThat(processor.currentStatus).isEqualTo(DeepFilterStatus.Active)
        val buffer = FloatArray(960) { 0.2f }
        assertThat(process(processor, buffer)).isTrue()
        assertThat(buffer.all { it.isFinite() }).isTrue()
    }

    @Test
    fun invalidateReturnsToIdleAndStopsProcessing() {
        val processor = NativeFixtures.deepFilter()
        processor.activate(1, 1024, 48_000.0)
        waitForActive(processor)
        processor.invalidate()
        assertThat(processor.currentStatus).isEqualTo(DeepFilterStatus.Idle)
        val samples = FloatArray(480) { 0.3f }
        assertThat(process(processor, samples)).isFalse()
        assertThat(samples.all { it == 0.3f }).isTrue()
    }

    private fun delayThroughChain(processor: NoiseReductionProcessor, signal: FloatArray, sampleRate: Double): Int =
        Signals.bestLag(signal, Buffers.render(processor, signal), (sampleRate * 0.45).toInt())

    @Test
    fun latencyDoesNotGrowWhenTheStreamIsReset() {
        val sampleRate = 22_050.0
        val signal = Signals.syllables(6.0, sampleRate)
        val processor = NativeFixtures.ready(NoiseReductionMode.DEEP_FILTER_NET, maxFrames = 4096)
        val first = delayThroughChain(processor, signal, sampleRate)
        assertThat(first).isGreaterThan(0)
        for (pass in 1..4) {
            processor.reset()
            assertWithMessage("latency after $pass reset(s)").that(delayThroughChain(processor, signal, sampleRate)).isEqualTo(first)
        }
    }

    @Test
    fun resetClearsAudioCarriedOverFromThePreviousPosition() {
        val sampleRate = 22_050.0
        val processor = NativeFixtures.ready(NoiseReductionMode.DEEP_FILTER_NET, maxFrames = 4096)
        delayThroughChain(processor, Signals.syllables(4.0, sampleRate), sampleRate)
        processor.reset()
        val block = FloatArray(4096)
        Buffers.processMono(processor, block)
        assertWithMessage("audio from before the reset leaked through").that(Signals.peak(block)).isLessThan(0.01f)
    }

    @Test
    fun stereoIsCollapsedToOneMonoMixThroughTheModel() {
        val sampleRate = 22_050.0
        val signal = Signals.syllables(6.0, sampleRate)
        val processor = NativeFixtures.ready(NoiseReductionMode.DEEP_FILTER_NET, channels = 2, maxFrames = 4096)
        val left = FloatArray(signal.size)
        val right = FloatArray(signal.size)
        var offset = 0
        while (offset < signal.size) {
            val count = minOf(4096, signal.size - offset)
            val block = Buffers.Block(2, count, interleaved = false)
            for (index in 0 until count) {
                block[0, index] = signal[offset + index]
                block[1, index] = signal[offset + index] * 0.6f
            }
            processor.process(block.buffers, block.lanes, count)
            block.buffers[0].copyInto(left, offset)
            block.buffers[1].copyInto(right, offset)
            offset += count
        }
        assertThat(left.toList()).isEqualTo(right.toList())
        val lag = Signals.bestLag(signal, left, (sampleRate * 0.45).toInt())
        assertThat(lag).isGreaterThan(0)
        assertThat(lag.toDouble()).isLessThan(sampleRate * 0.1)
        assertWithMessage("closing pause was not ducked").that(Signals.peak(left.copyOfRange(left.size - 2048, left.size))).isLessThan(0.02f)
    }

    @Test
    fun loadingInstallsTheLatestStrengthAndFocus() {
        val changed = NativeFixtures.deepFilter()
        changed.setAttenuationLimit(6f)
        changed.activate(1, 1024, 22_050.0)
        changed.setAttenuationLimit(100f)
        changed.setVoiceFocus(VoiceFocusPreset.STRONG)
        val reference = NativeFixtures.deepFilter()
        reference.setAttenuationLimit(100f)
        reference.setVoiceFocus(VoiceFocusPreset.STRONG)
        reference.activate(1, 1024, 22_050.0)
        waitForActive(changed)
        waitForActive(reference)
        for (pass in 0 until 60) {
            val expected = FloatArray(1024) { index ->
                val t = (pass * 1024 + index) / 22_050.0
                (0.015 * kotlin.math.sin(2 * Math.PI * 217 * t) + 0.009 * kotlin.math.sin(2 * Math.PI * 431 * t)).toFloat()
            }
            val actual = expected.copyOf()
            assertThat(process(changed, actual)).isTrue()
            assertThat(process(reference, expected)).isTrue()
            assertWithMessage("a setting changed while loading was not applied").that(Signals.maxDifference(actual, expected)).isLessThan(0.00001f)
        }
    }
}
