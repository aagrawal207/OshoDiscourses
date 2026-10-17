package com.agraabhi.oshodiscourses.denoise.dsp

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.roundToLong

/** A rational media timestamp in the shape of `CMTime`, so source-time checks match iOS. */
data class MediaTime(
    val value: Long,
    val timescale: Int,
    val epoch: Long = 0,
    val kind: Kind = Kind.NUMERIC,
) {
    enum class Kind { NUMERIC, INVALID, INDEFINITE, POSITIVE_INFINITY, NEGATIVE_INFINITY }

    val isValid: Boolean get() = kind != Kind.INVALID
    val isNumeric: Boolean get() = kind == Kind.NUMERIC && timescale > 0
    val seconds: Double get() = if (isNumeric) value.toDouble() / timescale else Double.NaN

    operator fun plus(other: MediaTime): MediaTime = combine(other, 1)

    operator fun minus(other: MediaTime): MediaTime = combine(other, -1)

    private fun combine(other: MediaTime, sign: Int): MediaTime {
        if (!isNumeric || !other.isNumeric) return INVALID
        val common = lcm(timescale.toLong(), other.timescale.toLong())
        if (common > Int.MAX_VALUE) {
            return fromSeconds(seconds + sign * other.seconds, max(timescale, other.timescale), epoch)
        }
        val left = value * (common / timescale)
        val right = other.value * (common / other.timescale)
        return MediaTime(left + sign * right, common.toInt(), epoch)
    }

    companion object {
        val ZERO = MediaTime(0, 1)
        val INVALID = MediaTime(0, 0, kind = Kind.INVALID)
        val INDEFINITE = MediaTime(0, 1, kind = Kind.INDEFINITE)
        val POSITIVE_INFINITY = MediaTime(0, 1, kind = Kind.POSITIVE_INFINITY)

        /** Rounds to the nearest tick, like `CMTime(seconds:preferredTimescale:)`. */
        fun fromSeconds(seconds: Double, timescale: Int, epoch: Long = 0): MediaTime =
            MediaTime((seconds * timescale).roundToLong(), timescale, epoch)

        private fun gcd(a: Long, b: Long): Long {
            var x = abs(a)
            var y = abs(b)
            while (y != 0L) {
                val t = x % y
                x = y
                y = t
            }
            return max(x, 1)
        }

        private fun lcm(a: Long, b: Long): Long = a / gcd(a, b) * b
    }
}

data class MediaTimeRange(val start: MediaTime, val duration: MediaTime) {
    /** Matches `CMTimeRange.isValid`: valid times and a non-negative, epoch-zero duration. */
    val isValid: Boolean
        get() = start.isValid && duration.isValid && duration.epoch == 0L &&
            (!duration.isNumeric || duration.value >= 0)

    /** The end keeps the start's epoch, as `CMTimeRangeGetEnd` does. */
    val end: MediaTime get() = (start + duration).let { if (it.isValid) it.copy(epoch = start.epoch) else it }

    companion object {
        val INVALID = MediaTimeRange(MediaTime.INVALID, MediaTime.INVALID)
        val ZERO = MediaTimeRange(MediaTime.ZERO, MediaTime.ZERO)
    }
}

/**
 * Tracks source time, not callback time (iOS `SourceAudioTimeline`): output durations change
 * with playback speed, but adjacent source ranges still share an endpoint.
 */
class SourceAudioTimeline {
    data class Observation(
        val validRange: Boolean,
        val requiresReset: Boolean,
        val timedDiscontinuity: Boolean,
        val gapSeconds: Double,
    )

    private var expectedStart: MediaTime? = null
    private var previousPrecision = 0.0
    private var untimedAudio = false

    fun reset() {
        expectedStart = null
        previousPrecision = 0.0
        untimedAudio = false
    }

    fun consume(range: MediaTimeRange, sampleRate: Double, startsStream: Boolean = false): Observation {
        if (startsStream) reset()
        val usable = range.isValid && range.start.isNumeric && range.duration.isNumeric &&
            range.duration.epoch == 0L && range.duration.value > 0
        val end = if (usable) range.end else MediaTime.INVALID
        if (!usable || !end.isNumeric || end.epoch != range.start.epoch) {
            val hadTimedAudio = expectedStart != null
            expectedStart = null
            untimedAudio = true
            return Observation(validRange = false, requiresReset = hadTimedAudio, timedDiscontinuity = false, gapSeconds = 0.0)
        }

        val previousEnd = expectedStart
        val precision = previousPrecision
        val recoveringTiming = untimedAudio
        expectedStart = end
        previousPrecision = 1.0 / range.start.timescale + 1.0 / range.duration.timescale
        untimedAudio = false
        if (previousEnd == null) {
            return Observation(validRange = true, requiresReset = recoveringTiming, timedDiscontinuity = false, gapSeconds = 0.0)
        }
        if (previousEnd.epoch != range.start.epoch) {
            return Observation(validRange = true, requiresReset = true, timedDiscontinuity = true, gapSeconds = 0.0)
        }
        val delta = range.start - previousEnd
        if (!delta.isNumeric || !delta.seconds.isFinite()) {
            return Observation(validRange = true, requiresReset = true, timedDiscontinuity = true, gapSeconds = 0.0)
        }
        // Each timestamp may round to its own timebase; allow those ticks plus two samples.
        val sampleSlack = if (sampleRate.isFinite() && sampleRate > 0) 2 / sampleRate else 0.0
        val tolerance = max(sampleSlack, precision + 1.0 / range.start.timescale)
        val gap = delta.seconds
        val discontinuity = abs(gap) > tolerance
        return Observation(
            validRange = true,
            requiresReset = discontinuity,
            timedDiscontinuity = discontinuity,
            gapSeconds = if (discontinuity) gap else 0.0,
        )
    }
}
