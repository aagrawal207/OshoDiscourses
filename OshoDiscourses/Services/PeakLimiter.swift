import Foundation

/// Keeps a signal from ever exceeding a ceiling, without look-ahead.
///
/// Attack is instantaneous by construction: the gain applied to a sample is never
/// larger than `ceiling / |sample|`, so the ceiling cannot be exceeded even for a
/// single sample and no delay line is required. Release is slow enough that gain
/// reduction rides over syllables rather than tracking individual waveform peaks,
/// which is what would distort them.
///
/// It is used for two jobs in this app:
///
/// - As a **safety net** after `VoiceFocusChain`, which adds gain (the lift and
///   the emphasis tilt) to an archive already mastered into full scale.
/// - As what **makes a volume boost possible at all**. This material peaks at
///   0 dBFS with roughly 14 dB of crest factor, so multiplying it does not make
///   it louder, it makes it clip. Limiting the peaks is what converts gain into
///   loudness instead of distortion.
///
/// Deliberately not a mastering limiter: no look-ahead, no soft knee, no
/// oversampling. It is here to be transparent when it is barely working and
/// honest rather than clever when it is working hard.
struct PeakLimiter {

    /// Just under full scale, leaving room for the intersample peaks a later
    /// resampling stage can reconstruct above the samples it was given.
    static let defaultCeiling: Float = 0.891   // -1 dBFS

    /// For the last stage before output, where nothing downstream will resample
    /// and reconstruct peaks above these samples. The extra 0.7 dB is worth having
    /// when the job is loudness.
    static let outputCeiling: Float = 0.966    // -0.3 dBFS

    private let ceiling: Float
    private let releaseCoefficient: Float
    /// Current gain reduction. 1 means the limiter is not acting.
    private(set) var gain: Float = 1

    init(
        sampleRate: Double,
        ceiling: Float = PeakLimiter.defaultCeiling,
        releaseSeconds: Double = 0.12
    ) {
        self.ceiling = ceiling
        self.releaseCoefficient = Float(exp(-1 / (max(releaseSeconds, 0.001) * sampleRate)))
    }

    mutating func reset() {
        gain = 1
    }

    mutating func process(_ sample: Float) -> Float {
        let magnitude = abs(sample)
        let required = magnitude > ceiling ? ceiling / magnitude : 1
        if required < gain {
            gain = required          // clamp immediately
        } else {
            gain = required + releaseCoefficient * (gain - required)
        }
        return sample * gain
    }
}
