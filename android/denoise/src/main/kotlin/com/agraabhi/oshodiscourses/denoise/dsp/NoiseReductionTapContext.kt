package com.agraabhi.oshodiscourses.denoise.dsp

import com.agraabhi.oshodiscourses.core.domain.player.DeepFilterStatus
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * One chain's DSP generation, sharing no state or counters (iOS `NoiseReductionTapContext`).
 * Media3 configures and feeds a chain on its playback thread, so preparation runs inline there.
 */
class NoiseReductionTapContext(
    val generation: Long,
    rnnoiseFactory: RNNoiseFactory = DefaultRNNoiseFactory,
    modelSource: DeepFilterModelSource = DeepFilterModelSource { null },
) {
    val stream = NoiseReductionStream(generation, rnnoiseFactory, modelSource)
    private val callbacks = ReentrantLock()
    private val retired = AtomicBoolean(false)
    @Volatile private var prepared = false
    private val sourceTimeline = SourceAudioTimeline()
    private val sourceTimeRanges = AtomicLong()
    private val sourceTimeDiscontinuities = AtomicLong()
    private val sourceTimeResets = AtomicLong()
    private val invalidSourceTimeRanges = AtomicLong()
    @Volatile private var lastSourceTimeGapSeconds = 0.0
    @Volatile private var formatRate = 0.0

    val isRetired: Boolean get() = retired.get()

    private val isPrepared: Boolean get() = prepared && !isRetired

    fun diagnosticsSnapshot(): NoiseReductionStream.Diagnostics {
        val snapshot = stream.diagnosticsSnapshot().copy(
            isPrepared = isPrepared,
            sourceTimeRanges = sourceTimeRanges.get(),
            sourceTimeDiscontinuities = sourceTimeDiscontinuities.get(),
            sourceTimeResets = sourceTimeResets.get(),
            invalidSourceTimeRanges = invalidSourceTimeRanges.get(),
            lastSourceTimeGapSeconds = lastSourceTimeGapSeconds,
        )
        return if (isRetired) snapshot.copy(deepFilterStatus = DeepFilterStatus.Idle) else snapshot
    }

    /** Serialised with [retire], so a retired generation can never publish readiness. */
    fun prepare(channelCount: Int, maxFrames: Int, sampleRate: Double, isSupportedPcm: Boolean = true) {
        callbacks.withLock {
            if (isRetired) return
            prepared = false
            sourceTimeline.reset()
            formatRate = sampleRate
            stream.prepare(channelCount, maxFrames, sampleRate, isSupportedPcm)
            prepared = stream.diagnosticsSnapshot().isPrepared && !isRetired
        }
    }

    fun unprepare() {
        callbacks.withLock {
            if (isRetired) return
            prepared = false
            stream.unprepare()
        }
    }

    /** Waits for an admitted callback, then frees this generation's native state. */
    fun retire() {
        callbacks.withLock {
            if (!retired.compareAndSet(false, true)) return
            prepared = false
        }
        stream.retire()
    }

    fun requestDiscontinuity() {
        if (!isRetired) stream.requestDiscontinuity()
    }

    /** A boundary owned by the caller's thread, such as a Media3 flush. */
    fun resetAtBoundary() {
        callbacks.withLock {
            if (isRetired) return
            sourceTimeline.reset()
            stream.resetAtBoundary()
        }
    }

    fun releaseModel() {
        if (!isRetired) stream.releaseModel()
    }

    /** Returns whether the buffers now hold processed audio; otherwise they are untouched. */
    fun processSourceAudio(buffers: Array<FloatArray>, channelsPerBuffer: IntArray, read: SourceRead): Boolean {
        // Even a retired generation must not expose undefined memory from a failed read.
        val validRead = read.status == 0 && read.returnedFrames >= 0 && read.returnedFrames <= read.requestedFrames
        if (!callbacks.tryLock()) {
            if (!validRead) {
                read.returnedFrames = 0
                read.startOfStream = false
            }
            if (!isRetired) stream.recordSkippedCallback()
            return false
        }
        try {
            if (isRetired) {
                if (!validRead) {
                    read.returnedFrames = 0
                    read.startOfStream = false
                }
                return false
            }
            if (!validRead || read.startOfStream) sourceTimeline.reset()
            val range = read.timeRange
            if (validRead && read.returnedFrames > 0 && range != null) {
                val observation = sourceTimeline.consume(range, formatRate)
                if (observation.validRange) sourceTimeRanges.incrementAndGet() else invalidSourceTimeRanges.incrementAndGet()
                if (observation.timedDiscontinuity) {
                    sourceTimeDiscontinuities.incrementAndGet()
                    lastSourceTimeGapSeconds = observation.gapSeconds
                }
                if (observation.requiresReset) {
                    sourceTimeResets.incrementAndGet()
                    read.startOfStream = true
                }
            }
            return stream.processSourceAudio(buffers, channelsPerBuffer, read, processingAllowed = isPrepared)
        } finally {
            callbacks.unlock()
        }
    }
}
