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
        static func peaking(frequency: Double, sampleRate: Double, q: Double, gainDb: Double) -> Biquad {
            let amplitude = pow(10, gainDb / 40)
            let omega = 2 * Double.pi * frequency / sampleRate
            let alpha = sin(omega) / (2 * q)
            let cosOmega = cos(omega)
            let a0 = 1 + alpha / amplitude
            return Biquad(
                b0: Float((1 + alpha * amplitude) / a0),
                b1: Float(-2 * cosOmega / a0),
                b2: Float((1 - alpha * amplitude) / a0),
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
        presence = .peaking(frequency: 1600, sampleRate: sampleRate, q: 0.9, gainDb: 3.5)
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

        guard parameters.emphasisEnabled else { return }
        for index in 0..<count {
            frame[index] = presence.process(highPass.process(frame[index]))
        }
    }

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
        for index in 0..<count {
            sumOfSquares += frame[index] * frame[index]
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
        return pow(10, min(deficit, parameters.liftMaxDb) / 20)
    }
}
