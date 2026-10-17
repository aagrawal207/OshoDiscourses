package com.agraabhi.oshodiscourses.denoise.dsp

import com.agraabhi.oshodiscourses.core.domain.player.DeepFilterStatus
import com.agraabhi.oshodiscourses.core.model.VoiceFocusPreset
import com.agraabhi.oshodiscourses.denoise.nativebridge.DeepFilterNative
import com.agraabhi.oshodiscourses.denoise.nativebridge.NativeDenoisers
import java.util.concurrent.Executor
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** Resolves the bundled model to a readable file path. Blocking; runs on the loader thread. */
fun interface DeepFilterModelSource {
    fun modelPath(): String?
}

/**
 * DeepFilterNet 3 at 48 kHz with rate conversion (iOS `DeepFilterProcessor`). Loading is
 * asynchronous; every failure is observable passthrough, never another denoiser.
 */
class DeepFilterProcessor(
    private val modelSource: DeepFilterModelSource,
    private val loader: Executor = DspExecutors.modelLoader,
    notifier: Executor = DspExecutors.maintenance,
) {
    /** One model instance per requested channel; a handle is never shared across channels. */
    private class Voice(val handle: Long, val hopSize: Int, parameters: VoiceFocusChain.Parameters) : AutoCloseable {
        val focus = VoiceFocusChain(MODEL_SAMPLE_RATE, parameters)
        private var stream: DenoiserStream? = null
        private val silence = FloatArray(hopSize)
        private val discardedOutput = FloatArray(hopSize)
        private val snr = FloatArray(1)
        private var closed = false

        private val transform = HopTransform { input, inputOffset, output ->
            if (DeepFilterNative.processFrame(handle, input, inputOffset, output, hopSize, snr) != DeepFilterNative.OK) {
                return@HopTransform false
            }
            focus.process(output, hopSize, snr[0])
            true
        }

        val isConfigured: Boolean get() = stream != null
        val maxFrames: Int get() = stream?.maxFrames ?: 0

        fun matches(sourceRate: Double, maxFrames: Int): Boolean =
            stream?.sourceRate == sourceRate && this.maxFrames >= maxFrames

        fun reconfigure(sourceRate: Double, maxFrames: Int) {
            stream = DenoiserStream(sourceRate, maxFrames, hopSize, bufferingHops = 2, slackFrames = 64)
            resetStreamState()
        }

        fun resetStreamState() {
            stream?.reset()
            focus.reset()
            flushModelState()
        }

        // Upstream init() appends spectra on every call, so dfb_reset grows latency by 5 hops.
        // Silence displaces stale spectra and keeps the running normalisation.
        private fun flushModelState() {
            if (hopSize <= 0) return
            repeat(FLUSH_HOPS) {
                if (DeepFilterNative.processFrame(handle, silence, 0, discardedOutput, hopSize, snr) != DeepFilterNative.OK) {
                    return
                }
            }
        }

        fun process(samples: FloatArray, offset: Int, count: Int): Boolean =
            stream?.process(samples, offset, count, transform) ?: false

        override fun close() {
            if (closed) return
            closed = true
            DeepFilterNative.destroy(handle)
        }
    }

    private val lock = ReentrantLock()
    private val voices = ArrayList<Voice>(2)
    private var status: DeepFilterStatus = DeepFilterStatus.Idle
    private var attenuationLimitDb = 100f
    private var parameters = VoiceFocusChain.Parameters.FOCUS
    private var sourceRate = 0.0
    private var maxFrames = 0
    private var requestedChannels = 1
    private var isLoading = false
    private var loadGeneration = 0L
    private var retired = false

    /** A completed attempt is not retried on every format change; [invalidate] clears it. */
    private var hasCompletedLoadAttempt = false
    private var statusObserver: ((DeepFilterStatus) -> Unit)? = null
    private val runtimeNotifications = CoalescedTask(notifier) { publishRuntimeFailure() }

    val currentStatus: DeepFilterStatus get() = lock.withLock { status }

    /** Set once during setup. The observer runs outside the lock, on any thread. */
    fun observeStatus(observer: (DeepFilterStatus) -> Unit) {
        val current = lock.withLock {
            statusObserver = observer
            status
        }
        observer(current)
    }

    private fun setStatusLocked(new: DeepFilterStatus): ((DeepFilterStatus) -> Unit)? {
        if (status == new) return null
        status = new
        return statusObserver
    }

    private fun publishRuntimeFailure() {
        val observer = lock.withLock {
            if (status != DeepFilterStatus.RuntimeFailure) return
            statusObserver
        }
        DspLog.error(LOG, "DeepFilterNet frame processing failed; passing audio through")
        observer?.invoke(DeepFilterStatus.RuntimeFailure)
    }

    /** The model blends aligned noisy and enhanced spectra itself; no external dry mix. */
    fun setAttenuationLimit(db: Float) {
        if (!db.isFinite() || db < 0) return
        lock.withLock {
            if (retired) return
            attenuationLimitDb = db
            for (voice in voices) DeepFilterNative.setAttenuationLimit(voice.handle, db)
        }
    }

    fun setVoiceFocus(preset: VoiceFocusPreset) {
        val next = VoiceFocusChain.Parameters.forPreset(preset)
        lock.withLock {
            if (retired) return
            parameters = next
            for (voice in voices) voice.focus.update(next)
        }
    }

    /** Returns at once; the first call loads the model on a background thread. */
    fun activate(channelCount: Int, maxFrames: Int, sampleRate: Double) {
        if (sampleRate < MINIMUM_SOURCE_RATE || sampleRate > MAXIMUM_SOURCE_RATE || maxFrames <= 0) {
            DspLog.error(LOG, "Refusing implausible source rate ${sampleRate.toInt()} Hz")
            val unsupported = DeepFilterStatus.UnsupportedSampleRate(sampleRate)
            val observer = lock.withLock {
                if (retired) return
                // Record even an unsupported request, so an older in-flight load cannot publish Active.
                sourceRate = sampleRate
                this.maxFrames = maxFrames
                setStatusLocked(unsupported)
            }
            observer?.invoke(unsupported)
            return
        }

        lock.lock()
        if (retired) {
            lock.unlock()
            return
        }
        sourceRate = sampleRate
        this.maxFrames = maxFrames
        val channels = maxOf(channelCount, 1)
        requestedChannels = channels
        if (voices.isNotEmpty()) {
            for (voice in voices) {
                if (!voice.matches(sampleRate, maxFrames)) voice.reconfigure(sampleRate, maxFrames) else voice.resetStreamState()
            }
            val missing = channels - voices.size
            val observer = setStatusLocked(if (missing > 0) DeepFilterStatus.Loading else DeepFilterStatus.Active)
            val value = status
            lock.unlock()
            observer?.invoke(value)
            if (missing > 0) loadModel(missing, replaceExisting = false)
            return
        }
        if (isLoading || hasCompletedLoadAttempt) {
            lock.unlock()
            return
        }
        lock.unlock()
        loadModel(channels, replaceExisting = true)
    }

    private fun loadModel(channelCount: Int, replaceExisting: Boolean) {
        val generation: Long
        val observer = lock.withLock {
            if (retired || isLoading) return
            if (sourceRate < MINIMUM_SOURCE_RATE || sourceRate > MAXIMUM_SOURCE_RATE || maxFrames <= 0) return
            isLoading = true
            loadGeneration += 1
            generation = loadGeneration
            setStatusLocked(DeepFilterStatus.Loading)
        }
        observer?.invoke(DeepFilterStatus.Loading)
        loader.execute { completeLoad(generation, channelCount, replaceExisting) }
    }

    /** Builds handles off the audio path, then installs them under the lock all at once. */
    private fun completeLoad(generation: Long, channelCount: Int, replaceExisting: Boolean) {
        val nativeReady = NativeDenoisers.isAvailable
        val path = if (nativeReady) modelSource.modelPath() else null
        val (attenuation, params, rate, frames) = lock.withLock {
            LoadRequest(attenuationLimitDb, parameters, sourceRate, maxFrames)
        }
        val built = ArrayList<Voice>(channelCount)
        var failed = path == null
        if (path != null) {
            for (index in 0 until channelCount) {
                val handle = DeepFilterNative.create(path, attenuation)
                if (handle == 0L) {
                    failed = true
                    break
                }
                val hop = DeepFilterNative.hopSize(handle)
                val modelRate = DeepFilterNative.sampleRate(handle)
                if (hop <= 0 || modelRate.toDouble() != MODEL_SAMPLE_RATE) {
                    DspLog.error(LOG, "Unexpected model geometry: hop $hop, rate $modelRate")
                    DeepFilterNative.destroy(handle)
                    failed = true
                    break
                }
                val voice = Voice(handle, hop, params)
                if (rate >= MINIMUM_SOURCE_RATE && rate <= MAXIMUM_SOURCE_RATE && frames > 0) voice.reconfigure(rate, frames)
                built.add(voice)
            }
        }

        lock.lock()
        if (generation != loadGeneration) {
            lock.unlock()
            built.forEach(Voice::close)
            return
        }
        isLoading = false
        hasCompletedLoadAttempt = true
        // activate() may have seen a newer format while ONNX parsing ran; fit to the latest.
        val installedRate = sourceRate
        val installedFrames = maxFrames
        val installedAttenuation = attenuationLimitDb
        val latestFormatIsSupported = installedRate >= MINIMUM_SOURCE_RATE &&
            installedRate <= MAXIMUM_SOURCE_RATE && installedFrames > 0
        if (!failed) {
            for (voice in built) {
                // A picker change during loading must reach the installed handle too.
                if (DeepFilterNative.setAttenuationLimit(voice.handle, installedAttenuation) != DeepFilterNative.OK) failed = true
                voice.focus.update(parameters)
                voice.focus.reset()
                if (latestFormatIsSupported && !voice.matches(installedRate, installedFrames)) {
                    voice.reconfigure(installedRate, installedFrames)
                }
            }
        }
        var missing = 0
        val observer: ((DeepFilterStatus) -> Unit)?
        if (failed || built.isEmpty()) {
            built.forEach(Voice::close)
            observer = setStatusLocked(if (nativeReady && path == null) DeepFilterStatus.ModelMissing else DeepFilterStatus.InitializationFailed)
        } else {
            if (replaceExisting) {
                voices.forEach(Voice::close)
                voices.clear()
            }
            voices.addAll(built)
            missing = maxOf(0, requestedChannels - voices.size)
            observer = setStatusLocked(
                when {
                    !latestFormatIsSupported -> DeepFilterStatus.UnsupportedSampleRate(installedRate)
                    missing == 0 -> DeepFilterStatus.Active
                    else -> DeepFilterStatus.Loading
                },
            )
        }
        val value = status
        val installedChannels = voices.size
        lock.unlock()

        when (value) {
            DeepFilterStatus.ModelMissing -> DspLog.error(LOG, "DeepFilterNet model is not available")
            DeepFilterStatus.InitializationFailed -> DspLog.error(LOG, "DeepFilterNet failed to initialize")
            DeepFilterStatus.Active -> DspLog.info(
                LOG,
                "DeepFilterNet active on $installedChannels channel(s) at ${installedRate.toInt()} Hz, " +
                    "attenuation limit $installedAttenuation dB",
            )
            else -> Unit
        }
        observer?.invoke(value)
        if (missing > 0 && latestFormatIsSupported) loadModel(missing, replaceExisting = false)
    }

    private data class LoadRequest(
        val attenuation: Float,
        val parameters: VoiceFocusChain.Parameters,
        val rate: Double,
        val frames: Int,
    )

    /** Clears streaming state after a seek or track change without unloading. */
    fun reset() {
        lock.withLock {
            if (retired) return
            for (voice in voices) if (voice.isConfigured) voice.resetStreamState()
        }
    }

    /** Drops the model and allows a later load attempt. */
    fun invalidate() {
        val observer = lock.withLock {
            if (retired) return
            loadGeneration += 1
            isLoading = false
            voices.forEach(Voice::close)
            voices.clear()
            hasCompletedLoadAttempt = false
            setStatusLocked(DeepFilterStatus.Idle)
        }
        observer?.invoke(DeepFilterStatus.Idle)
    }

    /** Cancels stale preparation when the stream cannot supply supported PCM. */
    fun rejectAudioFormat() {
        val observer = lock.withLock {
            if (retired) return
            loadGeneration += 1
            isLoading = false
            hasCompletedLoadAttempt = false
            sourceRate = 0.0
            maxFrames = 0
            setStatusLocked(DeepFilterStatus.UnsupportedAudioFormat)
        }
        observer?.invoke(DeepFilterStatus.UnsupportedAudioFormat)
    }

    /** A retired generation's in-flight preparation must never start another load. */
    fun retire() {
        val observer = lock.withLock {
            retired = true
            loadGeneration += 1
            isLoading = false
            voices.forEach(Voice::close)
            voices.clear()
            setStatusLocked(DeepFilterStatus.Idle)
        }
        observer?.invoke(DeepFilterStatus.Idle)
    }

    /** Denoises in place; false leaves the samples untouched. Never blocks on the lock. */
    fun process(samples: FloatArray, offset: Int, count: Int, channelIndex: Int): Boolean {
        if (count <= 0) return false
        if (!lock.tryLock()) return false
        try {
            if (status != DeepFilterStatus.Active || channelIndex < 0 || channelIndex >= voices.size) return false
            val voice = voices[channelIndex]
            if (!voice.isConfigured || count > voice.maxFrames) return false
            if (!voice.process(samples, offset, count)) {
                // Polling sees the failure at once; observers and logs run off the audio thread.
                setStatusLocked(DeepFilterStatus.RuntimeFailure)
                runtimeNotifications.signal()
                return false
            }
            return true
        } finally {
            lock.unlock()
        }
    }

    companion object {
        const val MODEL_SAMPLE_RATE = 48_000.0
        const val MINIMUM_SOURCE_RATE = 8_000.0
        const val MAXIMUM_SOURCE_RATE = 192_000.0
        private const val FLUSH_HOPS = 8
        private const val LOG = "DeepFilterNet"
    }
}
