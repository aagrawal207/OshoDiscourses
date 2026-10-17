package com.agraabhi.oshodiscourses.denoise.dsp

import com.agraabhi.oshodiscourses.core.model.NoiseReductionMode
import com.agraabhi.oshodiscourses.core.model.VoiceFocusPreset
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * Selects the current chain generation (iOS `NoiseReductionProcessor`). Direct calls use a
 * standalone stream, so their counters are never relabelled as a chain's.
 */
class NoiseReductionProcessor(
    private val rnnoiseFactory: RNNoiseFactory = DefaultRNNoiseFactory,
    private val modelSource: DeepFilterModelSource = DeepFilterModelSource { null },
) {
    private data class Configuration(
        val mode: NoiseReductionMode = NoiseReductionMode.RNNOISE,
        val wetMix: Float = 0.5f,
        val intensity: Float = 0.7f,
        val attenuationLimitDb: Float = 100f,
        val voiceFocus: VoiceFocusPreset = VoiceFocusPreset.FOCUS,
        val denoiseEnabled: Boolean = true,
        val outputGain: Float = 1f,
    ) {
        fun apply(stream: NoiseReductionStream) = stream.configure(
            mode, wetMix, intensity, attenuationLimitDb, voiceFocus, denoiseEnabled, outputGain,
        )
    }

    private val control = ReentrantLock()
    private val commands = ReentrantLock()
    private val standalone = NoiseReductionStream(null, rnnoiseFactory, modelSource)
    private val inactiveDeepFilter = DeepFilterProcessor(modelSource)
    private var configuration = Configuration()
    private var current: NoiseReductionTapContext? = null
    private var generationFence: Long? = null
    private var managesTaps = false

    /** The current generation's model, for status checks on the control thread. */
    val deepFilter: DeepFilterProcessor
        get() = control.withLock {
            current?.takeIf { !it.isRetired }?.stream?.deepFilter
                ?: if (managesTaps) inactiveDeepFilter else standalone.deepFilter
        }

    val currentGeneration: Long? get() = control.withLock { current?.generation }

    fun diagnosticsSnapshot(): NoiseReductionStream.Diagnostics {
        val (context, managed) = control.withLock { current to managesTaps }
        if (context != null) return context.diagnosticsSnapshot()
        return if (managed) NoiseReductionStream.Diagnostics() else standalone.diagnosticsSnapshot()
    }

    private fun target(): NoiseReductionStream? = current?.stream ?: if (managesTaps) null else standalone

    fun configure(
        mode: NoiseReductionMode,
        wetMix: Float,
        intensity: Float,
        attenuationLimitDb: Float,
        voiceFocus: VoiceFocusPreset,
        denoiseEnabled: Boolean = true,
        outputGain: Float = 1f,
    ) {
        commands.withLock {
            val (value, target) = control.withLock {
                configuration = Configuration(mode, wetMix, intensity, attenuationLimitDb, voiceFocus, denoiseEnabled, outputGain)
                configuration to target()
            }
            if (target != null) value.apply(target)
        }
    }

    fun setOutputGain(gain: Float) {
        commands.withLock {
            val target = control.withLock {
                configuration = configuration.copy(outputGain = gain)
                target()
            }
            target?.setOutputGain(gain)
        }
    }

    fun setDenoiseEnabled(enabled: Boolean) {
        commands.withLock {
            val target = control.withLock {
                configuration = configuration.copy(denoiseEnabled = enabled)
                target()
            }
            target?.setDenoiseEnabled(enabled)
        }
    }

    /** Generations strictly increase and cannot be reused after retirement. */
    fun makeTapContext(generation: Long): NoiseReductionTapContext? {
        commands.withLock {
            val previous: NoiseReductionTapContext?
            val context: NoiseReductionTapContext
            control.withLock {
                val fence = generationFence
                if (fence != null && generation <= fence) return null
                context = NoiseReductionTapContext(generation, rnnoiseFactory, modelSource)
                configuration.apply(context.stream)
                previous = current
                generationFence = generation
                managesTaps = true
                current = context
            }
            previous?.retire()
            return context
        }
    }

    /** Fences a generation even before its chain exists; an older retirement cannot detach a newer one. */
    fun retireTap(generation: Long) {
        commands.withLock {
            val previous = control.withLock {
                val fence = generationFence
                if (fence == null || generation > fence) generationFence = generation
                managesTaps = true
                current?.takeIf { it.generation == generation }?.also { current = null }
            }
            previous?.retire()
        }
    }

    /** Discontinuities name their generation, like retirement. */
    fun requestDiscontinuity(generation: Long) {
        val target = control.withLock { current?.takeIf { it.generation == generation } }
        target?.requestDiscontinuity()
    }

    /** Frees the current generation's DeepFilterNet model, for example while DeNoise is off. */
    fun releaseModel() {
        val target = control.withLock { current }
        target?.releaseModel()
    }

    // Direct entry points never relabel their counters as a chain's data.
    fun prepare(channelCount: Int, maxFrames: Int, sampleRate: Double, isSupportedPcm: Boolean = true) =
        standalone.prepare(channelCount, maxFrames, sampleRate, isSupportedPcm)

    fun process(buffers: Array<FloatArray>, channelsPerBuffer: IntArray, frameCount: Int, startOfStream: Boolean = false): Boolean =
        standalone.process(buffers, channelsPerBuffer, frameCount, startOfStream)

    fun processSourceAudio(buffers: Array<FloatArray>, channelsPerBuffer: IntArray, read: SourceRead): Boolean =
        standalone.processSourceAudio(buffers, channelsPerBuffer, read)

    fun reset() = standalone.reset()

    fun requestDiscontinuity() = standalone.requestDiscontinuity()
}
