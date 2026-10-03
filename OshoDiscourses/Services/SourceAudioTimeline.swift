import CoreMedia

/// Tracks asset time, not callback/wall time: post-effect buffer durations change
/// with playback speed, but adjacent source ranges still share an endpoint.
struct SourceAudioTimeline {
    struct Observation {
        let validRange: Bool
        let requiresReset: Bool
        let timedDiscontinuity: Bool
        let gapSeconds: Double
    }

    private var expectedStart: CMTime?
    private var previousPrecision: Double = 0
    private var untimedAudio = false

    mutating func reset() {
        expectedStart = nil
        previousPrecision = 0
        untimedAudio = false
    }

    mutating func consume(_ range: CMTimeRange, sampleRate: Double, startsStream: Bool = false) -> Observation {
        if startsStream { reset() }
        let usable = range.isValid && range.start.isNumeric && range.duration.isNumeric
            && range.start.timescale > 0 && range.duration.timescale > 0
            && range.duration.epoch == 0 && range.duration.value > 0
        let end = usable ? CMTimeRangeGetEnd(range) : .invalid
        guard usable, end.isNumeric, end.epoch == range.start.epoch else {
            let hadTimedAudio = expectedStart != nil
            expectedStart = nil
            untimedAudio = true
            return Observation(validRange: false, requiresReset: hadTimedAudio,
                               timedDiscontinuity: false, gapSeconds: 0)
        }

        let previousEnd = expectedStart
        let precision = previousPrecision
        let recoveringTiming = untimedAudio
        expectedStart = end
        previousPrecision = 1 / Double(range.start.timescale) + 1 / Double(range.duration.timescale)
        untimedAudio = false
        guard let previousEnd else {
            return Observation(validRange: true, requiresReset: recoveringTiming,
                               timedDiscontinuity: false, gapSeconds: 0)
        }
        if previousEnd.epoch != range.start.epoch {
            return Observation(validRange: true, requiresReset: true, timedDiscontinuity: true, gapSeconds: 0)
        }
        let delta = CMTimeSubtract(range.start, previousEnd)
        guard delta.isNumeric, delta.seconds.isFinite else {
            return Observation(validRange: true, requiresReset: true, timedDiscontinuity: true, gapSeconds: 0)
        }
        // Each timestamp may be rounded to its own rational timebase. Compute the
        // difference before conversion to Double, allowing those ticks plus sample slack.
        let sampleSlack = sampleRate.isFinite && sampleRate > 0 ? 2 / sampleRate : 0
        let tolerance = max(sampleSlack, precision + 1 / Double(range.start.timescale))
        let gap = delta.seconds
        let discontinuity = abs(gap) > tolerance
        return Observation(validRange: true, requiresReset: discontinuity,
                           timedDiscontinuity: discontinuity, gapSeconds: discontinuity ? gap : 0)
    }
}
