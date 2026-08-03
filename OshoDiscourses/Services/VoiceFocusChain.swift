import Foundation

/// Makes Osho's voice sit forward rather than trying to erase the noise.
///
/// Why this shape: on this archive the interfering sounds (an aircraft, traffic,
/// room tone) occupy 150-700 Hz — the *same* band as his voice — and there is
/// almost no energy above 3 kHz to work with. Measured on Ashtavakra Maha Geeta
/// #5 at 40:20, the plane holds 29.8%/59.1% of its energy in 150-300/300-700 Hz
/// against speech's 35.8%/51.0%. So subtractive EQ cannot separate them, and a
/// "presence" boost at 3-8 kHz would only amplify codec hiss.
///
/// What does work is raising the *contrast* between speech and everything else,
/// driven by DeepFilterNet's own per-frame local SNR estimate:
///
/// - **Ducking** noise-dominated frames pushes the aircraft down in the gaps
///   between sentences, where it is most obvious.
/// - **Speech-gated lifting** raises quiet speech toward a target level. Plain
///   compression was measured and rejected: it lifts the pauses too, cancelling
///   the ducking (contrast fell from +9.7 dB to +2.0 dB).
/// - **Gentle emphasis** trims below the male fundamental and lifts the
///   300-2500 Hz range that actually carries intelligibility here.
///
/// Measured speech-to-pause ratio on that segment (original +23.1 dB):
/// focus +33.9 dB, lift +32.2 dB, strong +33.7 dB.
final class VoiceFocusChain: @unchecked Sendable {

    struct Parameters: Sendable {
        /// Local SNR (dB) at or below which ducking is fully applied.
        var duckSnrLowDb: Float
        /// Local SNR (dB) at or above which no ducking is applied.
        var duckSnrHighDb: Float
        /// Maximum ducking depth in dB (negative).
        var duckFloorDb: Float
        /// Raise quiet speech toward this level (dBFS RMS per frame).
        var liftTargetDb: Float
        /// Never lift by more than this. Zero disables lifting.
        var liftMaxDb: Float
        /// Only lift when the model reports at least this much local SNR, so
        /// noise-only frames are never boosted.
        var liftMinSnrDb: Float
        /// After clear speech, keep the gate fully open for this long before any
        /// ducking may resume.
        ///
        /// This is what protects the ends of sentences. Osho trails off in level,
        /// so his final words carry a *low* local SNR and a plain SNR gate treats
        /// them as noise and mutes them. The hold keeps them intact, and also
        /// covers short gaps between clauses and the start of audience laughter.
        var holdMs: Float
        /// How long the gate takes to fall toward the floor once the hold has
        /// expired. Long values keep trailing words natural; short values reach
        /// the floor sooner inside genuine pauses.
        var closeMs: Float
        /// Apply the speech-band emphasis filters.
        var emphasisEnabled: Bool

        static let focus = Parameters(
            duckSnrLowDb: -5, duckSnrHighDb: 8, duckFloorDb: -14,
            liftTargetDb: 0, liftMaxDb: 0, liftMinSnrDb: 6,
            holdMs: 220, closeMs: 400, emphasisEnabled: true
        )

        static let lift = Parameters(
            duckSnrLowDb: -5, duckSnrHighDb: 8, duckFloorDb: -14,
            liftTargetDb: -20, liftMaxDb: 9, liftMinSnrDb: 6,
            holdMs: 220, closeMs: 400, emphasisEnabled: true
        )

        // Same hold as the others, so trailing words are equally protected, but
        // a faster fall afterwards so real pauses reach a deeper floor. This is
        // what makes Strong audibly different from Lift.
        static let strong = Parameters(
            duckSnrLowDb: -2, duckSnrHighDb: 10, duckFloorDb: -22,
            liftTargetDb: -20, liftMaxDb: 9, liftMinSnrDb: 6,
            holdMs: 150, closeMs: 240, emphasisEnabled: true
        )

        static func forPreset(_ preset: VoiceFocusPreset) -> Parameters {
            switch preset {
            case .focus: return .focus
            case .lift: return .lift
            case .strong: return .strong
            }
        }
    }

    /// Direct-form-1 biquad with persistent state, so filtering is continuous
    /// across frame boundaries.
    private struct Biquad {
        var b0: Float = 1, b1: Float = 0, b2: Float = 0
        var a1: Float = 0, a2: Float = 0
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

        mutating func process(_ input: Float) -> Float {
            let output = b0 * input + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = input
            y2 = y1; y1 = output
            return output
        }

        mutating func resetState() {
            x1 = 0; x2 = 0; y1 = 0; y2 = 0
        }

        /// Second-order Butterworth high-pass.
        static func highPass(frequency: Double, sampleRate: Double) -> Biquad {
            let omega = 2 * Double.pi * frequency / sampleRate
            let cosOmega = cos(omega)
            let alpha = sin(omega) / (2 * 0.7071)
            let a0 = 1 + alpha
            return Biquad(
                b0: Float((1 + cosOmega) / 2 / a0),
                b1: Float(-(1 + cosOmega) / a0),
                b2: Float((1 + cosOmega) / 2 / a0),
                a1: Float(-2 * cosOmega / a0),
                a2: Float((1 - alpha) / a0)
            )
        }

        /// Peaking bell.
        ///
        /// With `normalisingPeakToUnity`, the whole response is scaled down by the
        /// bell's gain so the boosted band reaches 0 dB instead of `gainDb`. The
        /// relative shape is identical; it just cannot add level.
        static func peaking(
            frequency: Double,
            sampleRate: Double,
            q: Double,
            gainDb: Double,
            normalisingPeakToUnity: Bool = false
        ) -> Biquad {
            let amplitude = pow(10, gainDb / 40)
            let omega = 2 * Double.pi * frequency / sampleRate
            let alpha = sin(omega) / (2 * q)
            let cosOmega = cos(omega)
            let a0 = 1 + alpha / amplitude
            let makeup = normalisingPeakToUnity ? pow(10, -gainDb / 20) : 1
            return Biquad(
                b0: Float(makeup * (1 + alpha * amplitude) / a0),
                b1: Float(makeup * -2 * cosOmega / a0),
                b2: Float(makeup * (1 - alpha * amplitude) / a0),
                a1: Float(-2 * cosOmega / a0),
                a2: Float((1 - alpha / amplitude) / a0)
            )
        }
    }

    private var parameters: Parameters
    private let sampleRate: Double

    private var highPass: Biquad
    private var presence: Biquad

    /// DeepFilterNet is causal but not zero-latency: measured with a tone burst,
    /// its output lags its input by 3 frames while the local-SNR estimate it
    /// returns leads the corresponding output audio by 2 frames. Applying a
    /// frame's gain to that same call's samples would therefore duck 20 ms early,
    /// clipping the tail of speech and releasing late. This ring buffer delays
    /// the SNR so gain lands on the audio it actually describes.
    static let snrAlignmentFrames = 2
    private var snrHistory: [Float]
    private var snrWriteIndex = 0

    /// Ducking and lifting are smoothed independently.
    ///
    /// The ducking envelope is a proper speech gate: **fast to open, slow to
    /// close**, with a hold in between. An earlier version had this inverted
    /// (10 ms to close), which muted the ends of Osho's sentences — his voice
    /// decays as a sentence finishes, so the SNR falls and the gate shut on top
    /// of the final words.
    private var duckGainState: Float = 1
    private var liftGainState: Float = 1
    /// Output ceiling, so the chain can never hand back a clipping sample.
    private var limiter: PeakLimiter
    private let duckOpen: Float
    private var duckClose: Float
    private let liftAttack: Float
    private let liftRelease: Float
    /// Samples of hold remaining before ducking may resume.
    private var holdRemaining = 0
    /// Running estimate of Osho's speech level, updated only on speech frames.
    /// Roughly a half-second time constant at 100 frames/second.
    private var speechLevelDb: Float = 0
    private static let speechLevelSmoothing: Float = 0.02
    /// How far 1.6 kHz sits above the rest of the band. Applied as a cut
    /// elsewhere rather than a boost here, so it adds no level.
    private static let emphasisGainDb: Double = 3.5

    init(sampleRate: Double, parameters: Parameters) {
        self.sampleRate = sampleRate
        self.parameters = parameters
        // Only true rumble is removed. Measured on the aircraft passage, below
        // 150 Hz is strongly speech-favoured (10.8% of speech energy against
        // 0.4% of the plane's), so cutting higher would throw away Osho's
        // fundamental to remove noise that is not there.
        highPass = .highPass(frequency: 90, sampleRate: sampleRate)
        // Emphasis sits above 700-1500 Hz on purpose: that band is where the
        // plane concentrates 9.3% of its energy against speech's 1.3%, so a bell
        // there (the first attempt used 900 Hz) amplifies noise more than voice.
        // 1.6 kHz is sparse in both, so lifting it raises consonants without
        // dragging up a large noise mass.
        //
        // The bell's gain is normalised away so its peak response is unity. This
        // archive is already mastered into full scale, so a bell that genuinely
        // *added* 3.5 dB simply clipped. Cutting everything else by 3.5 dB
        // instead keeps the tilt that was chosen by listening while adding no
        // gain of its own.
        presence = .peaking(
            frequency: 1600, sampleRate: sampleRate, q: 0.9, gainDb: Self.emphasisGainDb,
            normalisingPeakToUnity: true
        )
        // Seeded high so the first frames are not ducked before any SNR arrives.
        snrHistory = [Float](repeating: 30, count: max(Self.snrAlignmentFrames, 1))
        // Open quickly so a syllable onset is never clipped.
        duckOpen = exp(-1 / Float(0.008 * sampleRate))
        // Close slowly so trailing words fade out with the voice instead of
        // being cut off. Noise in genuinely long pauses still reaches the floor.
        duckClose = exp(-1 / (parameters.closeMs / 1000 * Float(sampleRate)))
        // Start at the target so no boost is applied until speech is measured.
        speechLevelDb = parameters.liftTargetDb
        liftAttack = exp(-1 / Float(0.020 * sampleRate))
        liftRelease = exp(-1 / Float(0.140 * sampleRate))
        limiter = PeakLimiter(sampleRate: sampleRate)
    }

    func update(parameters: Parameters) {
        self.parameters = parameters
        duckClose = exp(-1 / (parameters.closeMs / 1000 * Float(sampleRate)))
    }

    func reset() {
        highPass.resetState()
        presence.resetState()
        duckGainState = 1
        liftGainState = 1
        limiter.reset()
        holdRemaining = 0
        speechLevelDb = parameters.liftTargetDb
        for index in snrHistory.indices { snrHistory[index] = 30 }
        snrWriteIndex = 0
    }

    /// Apply focus to one DeepFilterNet output frame, in place.
    ///
    /// `localSnrDb` is the model's own estimate for the frame it just consumed,
    /// which is what makes speech and noise separable in time even when they
    /// overlap in frequency. It is delayed internally to line up with the audio
    /// this call returns.
    func process(frame: UnsafeMutablePointer<Float>, count: Int, localSnrDb: Float) {
        guard count > 0 else { return }

        // Swap in the SNR from `snrAlignmentFrames` ago.
        let alignedSnr = snrHistory[snrWriteIndex]
        snrHistory[snrWriteIndex] = localSnrDb
        snrWriteIndex = (snrWriteIndex + 1) % snrHistory.count

        // Clear speech re-arms the hold; otherwise it counts down.
        let isClearSpeech = alignedSnr.isFinite && alignedSnr >= parameters.duckSnrHighDb
        if isClearSpeech {
            holdRemaining = Int(parameters.holdMs / 1000 * Float(sampleRate))
        }
        let inHold = holdRemaining > 0
        if inHold {
            holdRemaining = max(holdRemaining - count, 0)
        }

        // Inside the hold window, never pull the voice down.
        let duckTarget = inHold ? 1 : duckGain(forSnr: alignedSnr)
        let liftTarget = liftGain(frame: frame, count: count, localSnrDb: alignedSnr, inHold: inHold)

        // Per-sample smoothing avoids the clicks a stepped gain would produce at
        // 100 frames/second.
        for index in 0..<count {
            let duckCoefficient = duckTarget > duckGainState ? duckOpen : duckClose
            duckGainState = duckTarget + duckCoefficient * (duckGainState - duckTarget)
            let liftCoefficient = liftTarget > liftGainState ? liftAttack : liftRelease
            liftGainState = liftTarget + liftCoefficient * (liftGainState - liftTarget)
            frame[index] *= duckGainState * liftGainState
        }

        // Emphasis and the safety limiter share one pass. The limiter has to come
        // last because the emphasis bell is itself a source of gain.
        for index in 0..<count {
            var sample = frame[index]
            if parameters.emphasisEnabled {
                sample = presence.process(highPass.process(sample))
            }
            frame[index] = limiter.process(sample)
        }
    }

    // MARK: - Output ceiling

    /// Why the chain needs a ceiling at all: this archive is already mastered into
    /// full scale — Maha Geeta #5 peaks at 0 dBFS — while this chain *adds* gain,
    /// up to `liftMaxDb` (9 dB) plus the emphasis tilt. Measured on 40:00-42:00 the
    /// output reached +3.3 dBFS with Focus and +10.1 dBFS with Lift and Strong, so
    /// roughly 0.3-0.4% of samples were being clipped by the output hardware.
    /// Clipped speech peaks crackle, and that was mistaken for a denoiser artifact.
    ///
    /// The limiter is a net, not the fix: on its own it engaged on 44% of samples,
    /// which is a compressor. The causes are handled above — the emphasis bell is
    /// normalised to unity peak and the lift is capped by the frame's own peak — so
    /// this now catches 0.005-0.04%.

    // MARK: - Gain rules

    /// Linear ducking gain interpolated across the SNR window.
    private func duckGain(forSnr snrDb: Float) -> Float {
        let floorGain = pow(10, parameters.duckFloorDb / 20)
        guard snrDb.isFinite else { return floorGain }
        if snrDb <= parameters.duckSnrLowDb { return floorGain }
        if snrDb >= parameters.duckSnrHighDb { return 1 }
        let span = parameters.duckSnrHighDb - parameters.duckSnrLowDb
        guard span > 0 else { return 1 }
        let position = (snrDb - parameters.duckSnrLowDb) / span
        return floorGain + position * (1 - floorGain)
    }

    /// Upward gain that tracks Osho's *speech* level over roughly half a second
    /// and applies one steady boost, rather than levelling each frame on its own.
    ///
    /// Per-frame levelling was measured and rejected: because it aims every frame
    /// at a fixed target, the quieter the frame the harder it boosts, so quiet
    /// noise in the gaps between clauses was amplified more than the voice itself
    /// (pauses came out +7.9 dB against speech's +3.7 dB). Tracking the speech
    /// level instead means gaps are never boosted above the voice.
    private func liftGain(
        frame: UnsafePointer<Float>,
        count: Int,
        localSnrDb: Float,
        inHold: Bool
    ) -> Float {
        guard parameters.liftMaxDb > 0 else { return 1 }

        var sumOfSquares: Float = 0
        var peak: Float = 0
        for index in 0..<count {
            let sample = frame[index]
            sumOfSquares += sample * sample
            peak = max(peak, abs(sample))
        }
        let rms = sqrt(sumOfSquares / Float(count))
        let levelDb = rms > 1e-6 ? 20 * log10(rms) : -120

        let speechLike = localSnrDb.isFinite && localSnrDb >= parameters.liftMinSnrDb
        // Only speech updates the running estimate, so noise cannot drag it.
        if speechLike, levelDb > -60 {
            speechLevelDb += Self.speechLevelSmoothing * (levelDb - speechLevelDb)
        }
        // Boost only while speech is present (or just was); never in open noise.
        guard speechLike || inHold else { return 1 }
        let deficit = parameters.liftTargetDb - speechLevelDb
        guard deficit > 0 else { return 1 }
        let wanted = pow(10, min(deficit, parameters.liftMaxDb) / 20)

        // The target is an RMS one, but clipping is a peak problem. Speech runs
        // roughly 18 dB of crest factor, so a frame sitting at -20 dBFS RMS is
        // already peaking near -2 dBFS and the full 9 dB of lift would push it
        // well past full scale. Cap the boost by what the frame's own peak can
        // take, which leaves the lift free to work on genuinely quiet passages —
        // where the headroom actually exists — and idle on loud ones.
        //
        // Clamped at unity: this is an upward-only control. Pulling anything down
        // is the ducking gain's job and, past the ceiling, the limiter's.
        guard peak > 1e-6 else { return wanted }
        return min(wanted, max(1, PeakLimiter.defaultCeiling / peak))
    }
}
