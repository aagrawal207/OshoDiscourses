package com.agraabhi.oshodiscourses.denoise.dsp

import com.agraabhi.oshodiscourses.core.model.VoiceFocusPreset
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Speech-to-pause contrast from the model's local SNR (iOS `VoiceFocusChain`): noise overlaps the
 * voice at 150-700 Hz, so it is ducked in time. Measurements: `docs/noise-reduction-lab.md`.
 */
class VoiceFocusChain(private val sampleRate: Double, parameters: Parameters) {

    data class Parameters(
        /** Local SNR (dB) at or below which ducking is fully applied. */
        val duckSnrLowDb: Float,
        /** Local SNR (dB) at or above which no ducking is applied. */
        val duckSnrHighDb: Float,
        /** Maximum ducking depth in dB (negative). */
        val duckFloorDb: Float,
        /** Quiet speech is raised toward this RMS level (dBFS). */
        val liftTargetDb: Float,
        /** Zero disables lifting. */
        val liftMaxDb: Float,
        /** Only frames at least this far above the noise are lifted. */
        val liftMinSnrDb: Float,
        /** Keeps the gate open after clear speech; protects Osho's decaying sentence ends. */
        val holdMs: Float,
        /** Fall time toward the floor once the hold expires. */
        val closeMs: Float,
        val emphasisEnabled: Boolean,
    ) {
        companion object {
            val FOCUS = Parameters(-5f, 8f, -14f, 0f, 0f, 6f, 220f, 400f, true)
            val LIFT = Parameters(-5f, 8f, -14f, -20f, 9f, 6f, 220f, 400f, true)

            // A faster fall after the same protective hold is what makes Strong distinct from Lift.
            val STRONG = Parameters(-2f, 10f, -22f, -20f, 9f, 6f, 150f, 240f, true)

            fun forPreset(preset: VoiceFocusPreset): Parameters = when (preset) {
                VoiceFocusPreset.FOCUS -> FOCUS
                VoiceFocusPreset.LIFT -> LIFT
                VoiceFocusPreset.STRONG -> STRONG
            }
        }
    }

    /** Direct-form-1 biquad whose state persists across frames. */
    private class Biquad(
        val b0: Float,
        val b1: Float,
        val b2: Float,
        val a1: Float,
        val a2: Float,
    ) {
        private var x1 = 0f
        private var x2 = 0f
        private var y1 = 0f
        private var y2 = 0f

        fun process(input: Float): Float {
            val output = b0 * input + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1
            x1 = input
            y2 = y1
            y1 = output
            return output
        }

        fun resetState() {
            x1 = 0f
            x2 = 0f
            y1 = 0f
            y2 = 0f
        }

        companion object {
            fun highPass(frequency: Double, sampleRate: Double): Biquad {
                val omega = 2 * Math.PI * frequency / sampleRate
                val cosOmega = cos(omega)
                val alpha = sin(omega) / (2 * 0.7071)
                val a0 = 1 + alpha
                return Biquad(
                    ((1 + cosOmega) / 2 / a0).toFloat(),
                    (-(1 + cosOmega) / a0).toFloat(),
                    ((1 + cosOmega) / 2 / a0).toFloat(),
                    (-2 * cosOmega / a0).toFloat(),
                    ((1 - alpha) / a0).toFloat(),
                )
            }

            /** Scaled so the bell's peak is unity: the tilt cuts elsewhere instead of boosting. */
            fun peakingNormalised(frequency: Double, sampleRate: Double, q: Double, gainDb: Double): Biquad {
                val amplitude = 10.0.pow(gainDb / 40)
                val omega = 2 * Math.PI * frequency / sampleRate
                val alpha = sin(omega) / (2 * q)
                val cosOmega = cos(omega)
                val a0 = 1 + alpha / amplitude
                val makeup = 10.0.pow(-gainDb / 20)
                return Biquad(
                    (makeup * (1 + alpha * amplitude) / a0).toFloat(),
                    (makeup * -2 * cosOmega / a0).toFloat(),
                    (makeup * (1 - alpha * amplitude) / a0).toFloat(),
                    (-2 * cosOmega / a0).toFloat(),
                    ((1 - alpha / amplitude) / a0).toFloat(),
                )
            }
        }
    }

    @Volatile private var parameters: Parameters = parameters

    // 90 Hz removes only rumble: below 150 Hz is strongly speech-favoured on this archive.
    private val highPass = Biquad.highPass(90.0, sampleRate)

    // 1.6 kHz is sparse in both speech and aircraft noise; 700-1500 Hz is plane-dominated.
    private val presence = Biquad.peakingNormalised(1600.0, sampleRate, 0.9, EMPHASIS_GAIN_DB)

    // The model's SNR leads its output audio by two frames; gain must land on matching audio.
    private val snrHistory = FloatArray(max(SNR_ALIGNMENT_FRAMES, 1)) { SEED_SNR }
    private var snrWriteIndex = 0

    private var duckGainState = 1f
    private var liftGainState = 1f
    private val limiter = PeakLimiter(sampleRate)

    // Fast to open so onsets survive, slow to close so trailing words fade with the voice.
    private val duckOpen = exp(-1 / (0.008 * sampleRate)).toFloat()
    private var duckClose = closeCoefficient(parameters.closeMs)
    private val liftAttack = exp(-1 / (0.020 * sampleRate)).toFloat()
    private val liftRelease = exp(-1 / (0.140 * sampleRate)).toFloat()
    private var holdRemaining = 0

    /** Running speech level, updated only on speech frames; starts at the target so nothing lifts early. */
    private var speechLevelDb = parameters.liftTargetDb

    private fun closeCoefficient(closeMs: Float): Float = exp(-1 / (closeMs / 1000 * sampleRate.toFloat()))

    /** Call from the thread that runs [process], or with it excluded. */
    fun update(parameters: Parameters) {
        if (this.parameters.liftMaxDb == 0f && parameters.liftMaxDb > 0f) {
            // Focus tracks no speech level; seed it without resetting the gate mid-sentence.
            speechLevelDb = parameters.liftTargetDb
        }
        this.parameters = parameters
        duckClose = closeCoefficient(parameters.closeMs)
    }

    fun reset() {
        highPass.resetState()
        presence.resetState()
        duckGainState = 1f
        liftGainState = 1f
        limiter.reset()
        holdRemaining = 0
        speechLevelDb = parameters.liftTargetDb
        snrHistory.fill(SEED_SNR)
        snrWriteIndex = 0
    }

    /** Applies focus in place to one model output frame of [count] samples. */
    fun process(frame: FloatArray, count: Int, localSnrDb: Float) {
        if (count <= 0) return
        val parameters = parameters

        val alignedSnr = snrHistory[snrWriteIndex]
        snrHistory[snrWriteIndex] = localSnrDb
        snrWriteIndex = (snrWriteIndex + 1) % snrHistory.size

        if (alignedSnr.isFinite() && alignedSnr >= parameters.duckSnrHighDb) {
            holdRemaining = (parameters.holdMs / 1000 * sampleRate.toFloat()).toInt()
        }
        val inHold = holdRemaining > 0
        if (inHold) holdRemaining = max(holdRemaining - count, 0)

        val duckTarget = if (inHold) 1f else duckGain(parameters, alignedSnr)
        val liftTarget = liftGain(parameters, frame, count, alignedSnr, inHold)

        // Per-sample smoothing avoids clicks from stepping gain 100 times a second.
        for (index in 0 until count) {
            val duckCoefficient = if (duckTarget > duckGainState) duckOpen else duckClose
            duckGainState = duckTarget + duckCoefficient * (duckGainState - duckTarget)
            val liftCoefficient = if (liftTarget > liftGainState) liftAttack else liftRelease
            liftGainState = liftTarget + liftCoefficient * (liftGainState - liftTarget)
            frame[index] *= duckGainState * liftGainState
        }

        // The limiter must come last because the emphasis bell is itself a source of gain.
        for (index in 0 until count) {
            var sample = frame[index]
            if (parameters.emphasisEnabled) sample = presence.process(highPass.process(sample))
            frame[index] = limiter.process(sample)
        }
    }

    private fun duckGain(parameters: Parameters, snrDb: Float): Float {
        val floorGain = 10f.pow(parameters.duckFloorDb / 20)
        if (!snrDb.isFinite()) return floorGain
        if (snrDb <= parameters.duckSnrLowDb) return floorGain
        if (snrDb >= parameters.duckSnrHighDb) return 1f
        val span = parameters.duckSnrHighDb - parameters.duckSnrLowDb
        if (span <= 0) return 1f
        val position = (snrDb - parameters.duckSnrLowDb) / span
        return floorGain + position * (1 - floorGain)
    }

    /**
     * One steady boost from the running speech level. Per-frame levelling boosted quiet
     * gaps harder than the voice (+7.9 dB against +3.7 dB).
     */
    private fun liftGain(parameters: Parameters, frame: FloatArray, count: Int, localSnrDb: Float, inHold: Boolean): Float {
        if (parameters.liftMaxDb <= 0f) return 1f
        var sumOfSquares = 0f
        var peak = 0f
        for (index in 0 until count) {
            val sample = frame[index]
            sumOfSquares += sample * sample
            peak = max(peak, abs(sample))
        }
        val rms = sqrt(sumOfSquares / count)
        val levelDb = if (rms > 1e-6f) 20 * log10(rms) else -120f

        val speechLike = localSnrDb.isFinite() && localSnrDb >= parameters.liftMinSnrDb
        if (speechLike && levelDb > -60f) speechLevelDb += SPEECH_LEVEL_SMOOTHING * (levelDb - speechLevelDb)
        if (!speechLike && !inHold) return 1f
        val deficit = parameters.liftTargetDb - speechLevelDb
        if (deficit <= 0f) return 1f
        val wanted = 10f.pow(min(deficit, parameters.liftMaxDb) / 20)
        // Speech carries ~18 dB of crest, so the frame's own peak caps the lift; never below unity.
        if (peak <= 1e-6f) return wanted
        return min(wanted, max(1f, PeakLimiter.DEFAULT_CEILING / peak))
    }

    companion object {
        const val SNR_ALIGNMENT_FRAMES = 2
        private const val SEED_SNR = 30f
        private const val SPEECH_LEVEL_SMOOTHING = 0.02f
        private const val EMPHASIS_GAIN_DB = 3.5
    }
}
