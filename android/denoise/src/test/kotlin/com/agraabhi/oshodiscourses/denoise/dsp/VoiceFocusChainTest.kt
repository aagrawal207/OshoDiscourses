package com.agraabhi.oshodiscourses.denoise.dsp

import com.agraabhi.oshodiscourses.core.model.VoiceFocusPreset
import com.google.common.truth.Truth.assertThat
import com.google.common.truth.Truth.assertWithMessage
import kotlin.math.PI
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.sin
import org.junit.Test

/** The pure-Kotlin Voice Focus half of the iOS `DeepFilterNetTests`. */
class VoiceFocusChainTest {
    private val rate = 48_000.0
    private val hop = 480

    private fun gainDb(after: FloatArray, before: Float): Float =
        20 * log10(max(Signals.rms(after), 1e-9f) / max(before, 1e-9f))

    @Test
    fun presetsAreDistinct() {
        val focus = VoiceFocusChain.Parameters.forPreset(VoiceFocusPreset.FOCUS)
        val lift = VoiceFocusChain.Parameters.forPreset(VoiceFocusPreset.LIFT)
        val strong = VoiceFocusChain.Parameters.forPreset(VoiceFocusPreset.STRONG)
        assertThat(focus.liftMaxDb).isEqualTo(0f)
        assertThat(lift.liftMaxDb).isGreaterThan(0f)
        assertThat(strong.liftMaxDb).isGreaterThan(0f)
        assertThat(strong.duckFloorDb).isLessThan(focus.duckFloorDb)
    }

    @Test
    fun voiceFocusRaisesSpeechToPauseContrast() {
        val frames = 600
        val generator = SplitMix64(7)
        val source = Array(frames) { frame ->
            val speaking = (frame / 150) % 2 == 0
            FloatArray(hop) { index ->
                val t = (frame * hop + index) / rate
                val noise = generator.nextUniform() * 0.05f
                if (!speaking) {
                    noise
                } else {
                    (0.25 * sin(2 * PI * 220 * t) + 0.12 * sin(2 * PI * 440 * t) + 0.06 * sin(2 * PI * 660 * t)).toFloat() + noise
                }
            }
        }
        val chain = VoiceFocusChain(rate, VoiceFocusChain.Parameters.FOCUS)
        val processed = source.mapIndexed { index, frame ->
            frame.copyOf().also { chain.process(it, it.size, if ((index / 150) % 2 == 0) 14f else -8f) }
        }
        fun average(frames: List<FloatArray>, speaking: Boolean): Float {
            val picked = frames.withIndex().filter { (index, _) -> ((index / 150) % 2 == 0) == speaking && index % 150 > 100 }
            return picked.map { Signals.rms(it.value) }.average().toFloat()
        }
        val before = 20 * log10(average(source.toList(), true) / average(source.toList(), false))
        val after = 20 * log10(average(processed, true) / average(processed, false))
        assertWithMessage("contrast gain ${after - before} dB").that(after).isGreaterThan(before + 6)
        assertThat(processed.all { frame -> frame.all { it.isFinite() } }).isTrue()
    }

    @Test
    fun gateDoesNotSwallowTheEndsOfSentences() {
        val generator = SplitMix64(31)
        var phase = 0.0
        fun tone(amplitude: Double) = FloatArray(hop) {
            phase += 2 * PI * 220 / rate
            (amplitude * (sin(phase) + 0.4 * sin(2 * phase) + 0.2 * sin(3 * phase))).toFloat() + generator.nextUniform() * 0.004f
        }
        val frames = ArrayList<Pair<FloatArray, Float>>()
        repeat(30) { frames += tone(0.25) to 16f }
        for (index in 0 until 25) {
            val fraction = index / 25.0
            frames += tone(0.25 * (1 - fraction) + 0.01) to (16 - 30 * fraction).toFloat()
        }
        repeat(250) { frames += FloatArray(hop) { generator.nextUniform() * 0.01f } to -14f }

        val chain = VoiceFocusChain(rate, VoiceFocusChain.Parameters.FOCUS)
        val gains = frames.map { (samples, snr) ->
            val before = Signals.rms(samples)
            val scratch = samples.copyOf()
            chain.process(scratch, scratch.size, snr)
            gainDb(scratch, before)
        }
        val mid = gains.subList(10, 30).average()
        val tail = gains.subList(30, 45).average()
        val pause = gains.takeLast(60).average()
        assertWithMessage("sentence tail ${mid - tail} dB below mid-speech").that(tail).isGreaterThan(mid - 6)
        assertWithMessage("pause $pause dB vs speech $mid dB").that(pause).isLessThan(mid - 8)
        assertThat(pause).isLessThan(-6.0)
    }

    @Test
    fun liftTracksSpeechLevelRatherThanEachFrame() {
        val chain = VoiceFocusChain(rate, VoiceFocusChain.Parameters.LIFT)
        val generator = SplitMix64(5)
        var lastGain = 0f
        repeat(120) {
            val frame = FloatArray(hop) { generator.nextUniform() * 0.004f }
            val before = Signals.rms(frame)
            chain.process(frame, frame.size, -12f)
            lastGain = gainDb(frame, before)
        }
        assertWithMessage("noise-only frames boosted by $lastGain dB").that(lastGain).isLessThan(0f)
    }

    @Test
    fun presetsRemainOrderedByAggressiveness() {
        val presets = VoiceFocusPreset.entries.map { VoiceFocusChain.Parameters.forPreset(it) }
        for (parameters in presets) {
            assertThat(parameters.holdMs).isAtLeast(120f)
            assertThat(parameters.closeMs).isAtLeast(200f)
        }
        val focus = VoiceFocusChain.Parameters.FOCUS
        val strong = VoiceFocusChain.Parameters.STRONG
        assertThat(strong.duckFloorDb).isLessThan(focus.duckFloorDb)
        assertThat(strong.closeMs).isAtMost(focus.closeMs)
    }

    @Test
    fun outputNeverClipsOnAFullScaleSource() {
        for (preset in VoiceFocusPreset.entries) {
            val chain = VoiceFocusChain(rate, VoiceFocusChain.Parameters.forPreset(preset))
            var phase = 0.0
            var worst = 0f
            for (frameIndex in 0 until 400) {
                val burst = frameIndex % 8 == 7
                val frame = FloatArray(hop) { index ->
                    val amplitude = if (burst && index < 60) 1f else 0.01f
                    (amplitude * sin(phase)).toFloat().also { phase += 2 * PI * 1600 / rate }
                }
                chain.process(frame, frame.size, 20f)
                worst = max(worst, Signals.peak(frame))
            }
            assertWithMessage("${preset.rawValue} hands back $worst").that(worst).isAtMost(1f)
        }
    }

    @Test
    fun emphasisAddsNoLevelOfItsOwn() {
        val chain = VoiceFocusChain(rate, VoiceFocusChain.Parameters.FOCUS)
        var phase = 0.0
        var worst = 0f
        for (frameIndex in 0 until 200) {
            val frame = FloatArray(hop) { (0.8 * sin(phase)).toFloat().also { phase += 2 * PI * 1600 / rate } }
            chain.process(frame, frame.size, 20f)
            if (frameIndex > 5) worst = max(worst, Signals.peak(frame))
        }
        assertWithMessage("emphasis added level: $worst").that(worst).isAtMost(0.81f)
    }

    @Test
    fun liftStillRaisesQuietSpeechThatHasHeadroom() {
        val chain = VoiceFocusChain(rate, VoiceFocusChain.Parameters.LIFT)
        var phase = 0.0
        var gain = 0f
        repeat(200) {
            val frame = FloatArray(hop) { (0.02 * sin(phase)).toFloat().also { phase += 2 * PI * 300 / rate } }
            val before = Signals.rms(frame)
            chain.process(frame, frame.size, 20f)
            gain = gainDb(frame, before)
        }
        assertWithMessage("quiet speech lifted by $gain dB").that(gain).isGreaterThan(3f)
    }

    @Test
    fun enablingLiftDoesNotWaitForANonLiftingLevelEstimate() {
        val chain = VoiceFocusChain(rate, VoiceFocusChain.Parameters.FOCUS)
        var before = 0f
        var after = 0f
        for (frameIndex in 0 until 125) {
            if (frameIndex == 100) chain.update(VoiceFocusChain.Parameters.LIFT)
            val frame = Signals.sine(300.0, rate, hop, amplitude = 0.02, startIndex = frameIndex * hop)
            chain.process(frame, frame.size, 20f)
            if (frameIndex == 99) before = Signals.rms(frame)
            if (frameIndex == 124) after = Signals.rms(frame)
        }
        assertThat(20 * log10(after / before)).isGreaterThan(2f)
    }
}
