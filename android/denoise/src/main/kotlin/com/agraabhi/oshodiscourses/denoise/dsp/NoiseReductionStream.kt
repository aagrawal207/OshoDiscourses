package com.agraabhi.oshodiscourses.denoise.dsp

import com.agraabhi.oshodiscourses.core.domain.player.DeepFilterStatus
import com.agraabhi.oshodiscourses.core.model.NoiseReductionMode
import com.agraabhi.oshodiscourses.core.model.VoiceFocusPreset
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/** Builds one channel's RNNoise at the source rate; null leaves that channel unprocessed. */
typealias RNNoiseFactory = (sourceRate: Double, maxFrames: Int, channel: Int) -> RNNoiseProcessor?

val DefaultRNNoiseFactory: RNNoiseFactory = { rate, frames, _ -> RNNoiseProcessor.create(rate, frames) }

/**
 * One read from the source, mirroring the tap's in/out arguments: a failed or malformed
 * read sets [returnedFrames] to 0 and clears [startOfStream]. Callers reuse one instance.
 */
class SourceRead {
    var requestedFrames = 0
    var returnedFrames = 0
    var startOfStream = false

    /** 0 is success, as with `OSStatus`. */
    var status = 0
    var timeRange: MediaTimeRange? = null

    fun set(requested: Int, returned: Int = requested, startOfStream: Boolean = false, status: Int = 0, timeRange: MediaTimeRange? = null): SourceRead {
        requestedFrames = requested
        returnedFrames = returned
        this.startOfStream = startOfStream
        this.status = status
        this.timeRange = timeRange
        return this
    }
}

/**
 * Mode routing, buffer outcomes, deferred resets and boost (iOS `NoiseReductionStream`). Buffers
 * mirror `AudioBufferList`: each array holds its `channelsPerBuffer` lanes interleaved.
 */
class NoiseReductionStream(
    tapGeneration: Long? = null,
    private val rnnoiseFactory: RNNoiseFactory = DefaultRNNoiseFactory,
    modelSource: DeepFilterModelSource = DeepFilterModelSource { null },
) {
    data class Diagnostics(
        val tapGeneration: Long? = null,
        val isPrepared: Boolean = false,
        val preparations: Long = 0,
        val deepFilterStatus: DeepFilterStatus = DeepFilterStatus.Idle,
        val processedBuffers: Long = 0,
        val disabledBuffers: Long = 0,
        val unpreparedBuffers: Long = 0,
        val invalidBuffers: Long = 0,
        val modelBypassedBuffers: Long = 0,
        val lockContendedBuffers: Long = 0,
        val sourceReadFailures: Long = 0,
        val sourceReadFailed: Boolean = false,
        val sourceDiscontinuities: Long = 0,
        val sourceTimeRanges: Long = 0,
        val sourceTimeDiscontinuities: Long = 0,
        val sourceTimeResets: Long = 0,
        val invalidSourceTimeRanges: Long = 0,
        val lastSourceTimeGapSeconds: Double = 0.0,
        val resetRequests: Long = 0,
        val streamResets: Long = 0,
        /** Subset of [modelBypassedBuffers] while a discontinuity reset is pending. */
        val resetBypassedBuffers: Long = 0,
        val resetPending: Boolean = false,
    )

    // Written only under lock, read without it: a status poll holding the lock would fail the
    // render path's try-lock, which skips a buffer and requests a reset during steady playback.
    private val tapGeneration = tapGeneration
    @Volatile private var preparations = 0L
    @Volatile private var isPreparedFlag = false
    @Volatile private var processedBuffers = 0L
    @Volatile private var disabledBuffers = 0L
    @Volatile private var invalidBuffers = 0L
    @Volatile private var modelBypassedBuffers = 0L
    @Volatile private var resetBypassedBuffers = 0L
    @Volatile private var streamResets = 0L

    private val lockContentions = AtomicLong()
    private val unpreparedCallbacks = AtomicLong()
    private val preparationBypasses = AtomicLong()
    private val sourceReadFailures = AtomicLong()
    private val sourceReadFailed = AtomicBoolean(false)
    private val sourceDiscontinuities = AtomicLong()
    private val requestedReset = AtomicLong()
    private val completedReset = AtomicLong()
    private val maintenance = CoalescedTask(DspExecutors.maintenance) { performPendingReset() }
    private var hasStreamState = false
    private var retired = false

    private var mode = NoiseReductionMode.RNNOISE
    private var wetMix = 0.5f
    private var intensity = 0.7f
    private var attenuationLimitDb = 100f

    /** Has its own try-lock, so a model load never blocks an audio callback. */
    val deepFilter = DeepFilterProcessor(modelSource)

    private var monoScratch = FloatArray(0)
    private var outputGain = 1f
    private var denoiseEnabled = true
    private var boostLimiters: Array<PeakLimiter> = emptyArray()
    private var channels: Array<Channel> = emptyArray()
    private var maxFrames = 0
    private val lock = ReentrantLock()

    /** Transposed-direct-form-2 biquad, reconfigured in place. */
    private class Biquad {
        private var b0 = 1f
        private var b1 = 0f
        private var b2 = 0f
        private var a1 = 0f
        private var a2 = 0f
        private var z1 = 0f
        private var z2 = 0f

        fun process(input: Float): Float {
            val output = b0 * input + z1
            z1 = b1 * input - a1 * output + z2
            z2 = b2 * input - a2 * output
            return output
        }

        fun reset() {
            z1 = 0f
            z2 = 0f
        }

        private fun set(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
            this.b0 = b0.toFloat()
            this.b1 = b1.toFloat()
            this.b2 = b2.toFloat()
            this.a1 = a1.toFloat()
            this.a2 = a2.toFloat()
            reset()
        }

        fun notch(frequency: Double, sampleRate: Double, q: Double) {
            val omega = 2 * Math.PI * frequency / sampleRate
            val alpha = sin(omega) / (2 * q)
            val a0 = 1 + alpha
            set(1 / a0, -2 * cos(omega) / a0, 1 / a0, -2 * cos(omega) / a0, (1 - alpha) / a0)
        }

        fun highPass(frequency: Double, sampleRate: Double) {
            val omega = 2 * Math.PI * frequency / sampleRate
            val alpha = sin(omega) / (2 * 0.707)
            val c = cos(omega)
            val a0 = 1 + alpha
            set((1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0, -2 * c / a0, (1 - alpha) / a0)
        }

        fun lowPass(frequency: Double, sampleRate: Double) {
            val omega = 2 * Math.PI * frequency / sampleRate
            val alpha = sin(omega) / (2 * 0.707)
            val c = cos(omega)
            val a0 = 1 + alpha
            set((1 - c) / 2 / a0, (1 - c) / a0, (1 - c) / 2 / a0, -2 * c / a0, (1 - alpha) / a0)
        }
    }

    private class Channel(maxFrames: Int) {
        var rnnoise: RNNoiseProcessor? = null
        val scratch = FloatArray(maxFrames)
        var sampleRate = 48_000.0
        val highPass = Biquad()
        val notch50 = Biquad()
        val notch60 = Biquad()
        val notch100 = Biquad()
        val notch120 = Biquad()
        val hissLowPass = Biquad()
        var envelope = 0f
        var quietSamples = 0
        var gateGain = 1f

        fun resetArchiveState() {
            highPass.reset()
            notch50.reset()
            notch60.reset()
            notch100.reset()
            notch120.reset()
            hissLowPass.reset()
            envelope = 0f
            quietSamples = 0
            gateGain = 1f
        }

        fun configureArchive(sampleRate: Double, intensity: Float) {
            this.sampleRate = sampleRate
            highPass.highPass(32.0, sampleRate)
            notch50.notch(50.0, sampleRate, 35.0)
            notch60.notch(60.0, sampleRate, 35.0)
            notch100.notch(100.0, sampleRate, 42.0)
            notch120.notch(120.0, sampleRate, 42.0)
            val cutoff = 14_000 - 3_500 * intensity.toDouble()
            hissLowPass.lowPass(min(cutoff, sampleRate * 0.45), sampleRate)
            envelope = 0f
            quietSamples = 0
            gateGain = 1f
        }

        fun close() {
            rnnoise?.close()
            rnnoise = null
        }
    }

    /** A control-thread snapshot that takes no lock the render path try-locks. */
    fun diagnosticsSnapshot(): Diagnostics {
        val requests = requestedReset.get()
        return Diagnostics(
            tapGeneration = tapGeneration,
            isPrepared = isPreparedFlag,
            preparations = preparations,
            processedBuffers = processedBuffers,
            disabledBuffers = disabledBuffers,
            invalidBuffers = invalidBuffers,
            modelBypassedBuffers = modelBypassedBuffers + preparationBypasses.get(),
            resetBypassedBuffers = resetBypassedBuffers,
            streamResets = streamResets,
            unpreparedBuffers = unpreparedCallbacks.get(),
            deepFilterStatus = deepFilter.currentStatus,
            lockContendedBuffers = lockContentions.get(),
            sourceReadFailures = sourceReadFailures.get(),
            sourceReadFailed = sourceReadFailed.get(),
            sourceDiscontinuities = sourceDiscontinuities.get(),
            resetRequests = requests,
            resetPending = requests != completedReset.get(),
        )
    }

    fun configure(
        mode: NoiseReductionMode,
        wetMix: Float,
        intensity: Float,
        attenuationLimitDb: Float,
        voiceFocus: VoiceFocusPreset,
        denoiseEnabled: Boolean = true,
        outputGain: Float = 1f,
    ) {
        lock.lock()
        if (retired) {
            lock.unlock()
            return
        }
        val modeChanged = this.mode != mode
        val enabling = !this.denoiseEnabled && denoiseEnabled
        this.mode = mode
        this.denoiseEnabled = denoiseEnabled
        this.outputGain = max(outputGain, 1f)
        this.wetMix = wetMix.coerceIn(0f, 1f)
        this.intensity = intensity.coerceIn(0f, 1f)
        this.attenuationLimitDb = max(attenuationLimitDb, 0f)
        for ((index, channel) in channels.withIndex()) {
            channel.configureArchive(channel.sampleRate, this.intensity)
            if (modeChanged) {
                channel.rnnoise?.reset()
                if (mode == NoiseReductionMode.RNNOISE && channel.rnnoise == null) {
                    channel.rnnoise = rnnoiseFactory(channel.sampleRate, maxFrames, index)
                }
            }
        }
        val formatRate = channels.firstOrNull()?.sampleRate
        val formatFrames = maxFrames
        val attenuation = this.attenuationLimitDb
        lock.unlock()

        // DeepFilterNet keeps its own state and lock, so it is driven outside this one.
        deepFilter.setAttenuationLimit(attenuation)
        deepFilter.setVoiceFocus(voiceFocus)
        if (mode == NoiseReductionMode.DEEP_FILTER_NET && denoiseEnabled && (modeChanged || enabling)) {
            if (formatRate != null && formatFrames > 0) deepFilter.activate(1, formatFrames, formatRate)
        } else if (modeChanged) {
            // Keep the loaded model so switching back does not pay the load again.
            deepFilter.reset()
        }
    }

    /** Volume changes must not touch the denoisers' configuration or filter histories. */
    fun setOutputGain(gain: Float) {
        lock.withLock {
            if (retired) return
            val next = max(gain, 1f)
            if (outputGain > 1f && next <= 1f) boostLimiters.forEach(PeakLimiter::reset)
            outputGain = next
        }
    }

    /** Updates the passthrough boundary without activating a model against a stale format. */
    fun setDenoiseEnabled(enabled: Boolean) {
        lock.withLock {
            if (retired) return
            denoiseEnabled = enabled
        }
    }

    /** Allocates per-channel state for this format. [isSupportedPcm] false rejects it. */
    fun prepare(channelCount: Int, maxFrames: Int, sampleRate: Double, isSupportedPcm: Boolean = true) {
        lock.lock()
        if (retired) {
            lock.unlock()
            return
        }
        preparations += 1
        teardownLocked()
        if (!isSupportedPcm || channelCount <= 0 || maxFrames <= 0 ||
            sampleRate < DeepFilterProcessor.MINIMUM_SOURCE_RATE || sampleRate > DeepFilterProcessor.MAXIMUM_SOURCE_RATE
        ) {
            this.maxFrames = 0
            lock.unlock()
            deepFilter.rejectAudioFormat()
            DspLog.error(LOG, "Rejected unsupported audio stream configuration")
            return
        }
        this.maxFrames = maxFrames
        channels = Array(channelCount) { index ->
            Channel(maxFrames).also { channel ->
                channel.configureArchive(sampleRate, intensity)
                if (mode == NoiseReductionMode.RNNOISE) channel.rnnoise = rnnoiseFactory(sampleRate, maxFrames, index)
            }
        }
        isPreparedFlag = true
        monoScratch = FloatArray(max(maxFrames, 1))
        // Tighter than the voice chain's ceiling: nothing after this stage reconstructs peaks.
        boostLimiters = Array(max(channelCount, 1)) { PeakLimiter(sampleRate, PeakLimiter.OUTPUT_CEILING) }
        val activeMode = mode
        val denoiseActive = denoiseEnabled
        hasStreamState = false
        completedReset.set(requestedReset.get())
        lock.unlock()

        DspLog.info(LOG, "Prepared ${activeMode.rawValue}, $channelCount channels at ${sampleRate.toInt()} Hz")
        // One model on a mono mix rather than one per channel.
        if (activeMode == NoiseReductionMode.DEEP_FILTER_NET && denoiseActive) deepFilter.activate(1, maxFrames, sampleRate)
    }

    /** Synchronous control-thread reset; audio callbacks use [requestDiscontinuity]. */
    fun reset() {
        lock.withLock {
            if (retired) return
            resetLocked()
            completedReset.set(requestedReset.get())
        }
    }

    /**
     * A boundary the caller already owns, such as a Media3 flush: clears history at once,
     * so the next buffer is processed instead of bypassed while a deferred reset runs.
     */
    fun resetAtBoundary() {
        sourceDiscontinuities.incrementAndGet()
        lock.withLock {
            if (retired) return
            if (hasStreamState) resetLocked()
            completedReset.set(requestedReset.get())
        }
    }

    private fun resetLocked() {
        for (channel in channels) {
            channel.rnnoise?.reset()
            channel.resetArchiveState()
            channel.scratch.fill(0f)
        }
        monoScratch.fill(0f)
        boostLimiters.forEach(PeakLimiter::reset)
        deepFilter.reset()
        hasStreamState = false
        streamResets += 1
    }

    /** Requests a clean boundary without taking processor locks; native state clears off-thread. */
    fun requestDiscontinuity() {
        requestedReset.incrementAndGet()
        maintenance.signal()
    }

    private fun performPendingReset() {
        lock.withLock {
            if (retired) return
            if (requestedReset.get() == completedReset.get()) return
            if (hasStreamState) resetLocked()
            // No samples enter while the lock is held, so one reset covers every boundary so far.
            completedReset.set(requestedReset.get())
        }
    }

    private fun teardownLocked() {
        channels.forEach(Channel::close)
        channels = emptyArray()
        monoScratch = FloatArray(0)
        hasStreamState = false
        isPreparedFlag = false
    }

    fun unprepare() {
        lock.withLock { isPreparedFlag = false }
        requestDiscontinuity()
    }

    /** Frees the model's memory; a later activation loads it again. */
    fun releaseModel() {
        deepFilter.invalidate()
    }

    fun retire() {
        lock.withLock {
            retired = true
            teardownLocked()
            completedReset.set(requestedReset.get())
        }
        deepFilter.retire()
    }

    fun recordSkippedCallback() {
        lockContentions.incrementAndGet()
        requestDiscontinuity()
    }

    /**
     * Processes [frameCount] frames in place. Returns true only when every channel was
     * processed by the current generation; otherwise all source samples stay raw.
     */
    fun process(
        buffers: Array<FloatArray>,
        channelsPerBuffer: IntArray,
        frameCount: Int,
        startOfStream: Boolean = false,
        processingAllowed: Boolean = true,
    ): Boolean {
        if (startOfStream) {
            sourceDiscontinuities.incrementAndGet()
            requestedReset.incrementAndGet()
        }
        val n = frameCount
        if (!processingAllowed && n > 0) {
            preparationBypasses.incrementAndGet()
            return false
        }
        if (n <= 0) {
            if (requestedReset.get() != completedReset.get()) maintenance.signal()
            return false
        }
        // Audio callbacks never wait for preparation or configuration to finish.
        if (!lock.tryLock()) {
            lockContentions.incrementAndGet()
            requestDiscontinuity()
            return false
        }
        try {
            if (retired) return false
            val generation = requestedReset.get()
            if (generation != completedReset.get()) {
                if (hasStreamState) {
                    modelBypassedBuffers += 1
                    resetBypassedBuffers += 1
                    maintenance.signal()
                    return false
                }
                // Preparation or a completed reset already cleared everything.
                completedReset.set(generation)
            }
            if (channels.isEmpty()) {
                unpreparedCallbacks.incrementAndGet()
                return false
            }
            if (!denoiseEnabled) {
                disabledBuffers += 1
                return false
            }
            if (n > maxFrames) {
                invalidBuffers += 1
                requestDiscontinuity()
                return false
            }
            var totalChannels = 0
            for (index in buffers.indices) {
                val count = if (index < channelsPerBuffer.size) channelsPerBuffer[index] else 0
                if (count <= 0 || buffers[index].size < n * count) {
                    invalidBuffers += 1
                    requestDiscontinuity()
                    return false
                }
                totalChannels += count
            }
            if (totalChannels != channels.size) {
                invalidBuffers += 1
                requestDiscontinuity()
                return false
            }

            var processed = true
            if (mode == NoiseReductionMode.DEEP_FILTER_NET) {
                processed = processDeepFilterNet(buffers, channelsPerBuffer, n)
            } else {
                hasStreamState = true
                var channelIndex = 0
                for (bufferIndex in buffers.indices) {
                    val samples = buffers[bufferIndex]
                    val lanes = channelsPerBuffer[bufferIndex]
                    for (lane in 0 until lanes) {
                        val channel = channels[channelIndex]
                        val input = channel.scratch
                        for (frame in 0 until n) input[frame] = samples[frame * lanes + lane]
                        val handled = when (mode) {
                            NoiseReductionMode.RNNOISE -> channel.rnnoise?.process(input, 0, n, wetMix) == true
                            NoiseReductionMode.CADENCE -> {
                                processCadence(input, n, channel)
                                true
                            }
                            NoiseReductionMode.DEEP_FILTER_NET -> true
                        }
                        processed = handled && processed
                        channelIndex += 1
                    }
                }
            }
            if (processed) hasStreamState = true
            if (requestedReset.get() != generation) {
                processed = false
                resetBypassedBuffers += 1
            }

            // Commit only a complete current-generation result; a later channel's failure or a
            // concurrent boundary leaves every source channel raw.
            if (processed) {
                if (mode == NoiseReductionMode.DEEP_FILTER_NET) {
                    val output = monoScratch
                    for (bufferIndex in buffers.indices) {
                        val samples = buffers[bufferIndex]
                        val lanes = channelsPerBuffer[bufferIndex]
                        for (frame in 0 until n) {
                            for (lane in 0 until lanes) samples[frame * lanes + lane] = output[frame]
                        }
                    }
                } else {
                    var channelIndex = 0
                    for (bufferIndex in buffers.indices) {
                        val samples = buffers[bufferIndex]
                        val lanes = channelsPerBuffer[bufferIndex]
                        for (lane in 0 until lanes) {
                            val output = channels[channelIndex].scratch
                            for (frame in 0 until n) samples[frame * lanes + lane] = output[frame]
                            channelIndex += 1
                        }
                    }
                }
                processedBuffers += 1
                applyOutputBoost(buffers, channelsPerBuffer, n)
            } else {
                modelBypassedBuffers += 1
                if (hasStreamState) requestDiscontinuity()
            }
            return processed
        } finally {
            lock.unlock()
        }
    }

    /**
     * A failed read's memory is undefined, so it returns no audio and recovery starts
     * from cleared history. Returns whether the buffers now hold processed audio.
     */
    fun processSourceAudio(
        buffers: Array<FloatArray>,
        channelsPerBuffer: IntArray,
        read: SourceRead,
        processingAllowed: Boolean = true,
    ): Boolean {
        if (read.status != 0 || read.returnedFrames < 0 || read.returnedFrames > read.requestedFrames) {
            read.returnedFrames = 0
            read.startOfStream = false
            sourceReadFailures.incrementAndGet()
            sourceReadFailed.set(true)
            requestDiscontinuity()
            return false
        }
        sourceReadFailed.set(false)
        return process(buffers, channelsPerBuffer, read.returnedFrames, read.startOfStream, processingAllowed)
    }

    /**
     * Gain inside the chain, then a limiter: this archive peaks at 0 dBFS with ~14 dB of
     * crest, so only limiting turns gain into loudness. Raw playback never reaches here.
     */
    private fun applyOutputBoost(buffers: Array<FloatArray>, channelsPerBuffer: IntArray, n: Int) {
        val gain = outputGain
        if (gain <= 1.0001f) return
        var channelIndex = 0
        for (bufferIndex in buffers.indices) {
            val samples = buffers[bufferIndex]
            val lanes = channelsPerBuffer[bufferIndex]
            for (lane in 0 until lanes) {
                val limiter = boostLimiters[channelIndex]
                for (frame in 0 until n) {
                    val offset = frame * lanes + lane
                    samples[offset] = limiter.process(samples[offset] * gain)
                }
                channelIndex += 1
            }
        }
    }

    /**
     * One model on a mono mix: the joint-stereo downloads differ by only -18.4 dB between
     * channels, and two independent gates made the stereo image wander.
     */
    private fun processDeepFilterNet(buffers: Array<FloatArray>, channelsPerBuffer: IntArray, n: Int): Boolean {
        if (n > maxFrames || monoScratch.size < n) return false
        val scratch = monoScratch
        scratch.fill(0f, 0, n)
        for (bufferIndex in buffers.indices) {
            val samples = buffers[bufferIndex]
            val lanes = channelsPerBuffer[bufferIndex]
            for (frame in 0 until n) {
                for (lane in 0 until lanes) scratch[frame] += samples[frame * lanes + lane]
            }
        }
        val scale = 1f / channels.size
        for (frame in 0 until n) scratch[frame] *= scale
        // False means the model left the mix alone; the caller then keeps the source's own width.
        return deepFilter.process(scratch, 0, n, 0)
    }

    private fun processCadence(samples: FloatArray, count: Int, channel: Channel) {
        val sampleRate = channel.sampleRate.toFloat()
        val envelopeAttack = exp(-1 / (0.008f * sampleRate))
        val envelopeRelease = exp(-1 / (0.22f * sampleRate))
        val gateOpen = exp(-1 / (0.006f * sampleRate))
        val gateClose = exp(-1 / (0.35f * sampleRate))
        val quietHold = (sampleRate * (0.22f + 0.18f * (1 - intensity))).toInt()
        val quietThreshold = 0.009f
        val quietGain = 1 - 0.82f * intensity

        for (index in 0 until count) {
            val dry = samples[index]
            var filtered = channel.highPass.process(dry)
            filtered = channel.notch50.process(filtered)
            filtered = channel.notch60.process(filtered)
            filtered = channel.notch100.process(filtered)
            filtered = channel.notch120.process(filtered)
            filtered = channel.hissLowPass.process(filtered)

            val level = abs(filtered)
            val envelopeCoefficient = if (level > channel.envelope) envelopeAttack else envelopeRelease
            channel.envelope = level + envelopeCoefficient * (channel.envelope - level)
            channel.quietSamples = if (channel.envelope < quietThreshold) channel.quietSamples + 1 else 0

            val targetGain = if (channel.quietSamples >= quietHold) quietGain else 1f
            val gateCoefficient = if (targetGain > channel.gateGain) gateOpen else gateClose
            channel.gateGain = targetGain + gateCoefficient * (channel.gateGain - targetGain)

            val processed = filtered * channel.gateGain
            samples[index] = dry + intensity * (processed - dry)
        }
    }

    private companion object {
        const val LOG = "NoiseReduction"
    }
}
