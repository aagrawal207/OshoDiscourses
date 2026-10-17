package com.agraabhi.oshodiscourses.denoise.media3

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.AudioProcessor.AudioFormat
import androidx.media3.common.audio.BaseAudioProcessor
import com.agraabhi.oshodiscourses.denoise.dsp.DeepFilterProcessor
import com.agraabhi.oshodiscourses.denoise.dsp.NoiseReductionTapContext
import com.agraabhi.oshodiscourses.denoise.dsp.SourceRead
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.roundToInt

/**
 * One chain generation's DSP in Media3's sink. Output keeps the input format; fixed chunks keep
 * scratch allocation to format changes, and unprocessed chunks are copied byte for byte.
 */
class NoiseReductionAudioProcessor internal constructor(
    private val context: NoiseReductionTapContext,
) : BaseAudioProcessor() {
    private var preparedFormat: AudioFormat? = null
    private var channelCount = 0
    private var interleaved = FloatArray(0)
    private var buffers: Array<FloatArray> = arrayOf(interleaved)
    private var lanes = IntArray(1)
    private val read = SourceRead()

    val generation: Long get() = context.generation

    override fun onConfigure(inputAudioFormat: AudioFormat): AudioFormat {
        if (!isSupported(inputAudioFormat)) {
            // Inactive rather than throwing: an unhandled format would fail playback itself.
            preparedFormat = null
            context.prepare(inputAudioFormat.channelCount, CHUNK_FRAMES, inputAudioFormat.sampleRate.toDouble(), isSupportedPcm = false)
            return AudioFormat.NOT_SET
        }
        return inputAudioFormat
    }

    override fun onFlush(streamMetadata: AudioProcessor.StreamMetadata) {
        val format = inputAudioFormat
        if (format != preparedFormat) prepareFor(format) else context.resetAtBoundary()
    }

    override fun onReset() {
        preparedFormat = null
        context.unprepare()
        context.releaseModel()
    }

    private fun prepareFor(format: AudioFormat) {
        if (!isSupported(format)) return
        channelCount = format.channelCount
        interleaved = FloatArray(CHUNK_FRAMES * channelCount)
        buffers = arrayOf(interleaved)
        lanes = intArrayOf(channelCount)
        context.prepare(channelCount, CHUNK_FRAMES, format.sampleRate.toDouble())
        preparedFormat = format
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        val start = inputBuffer.position()
        val limit = inputBuffer.limit()
        val size = limit - start
        if (size <= 0) return
        val format = inputAudioFormat
        if (format != preparedFormat) prepareFor(format)
        val output = replaceOutputBuffer(size)
        val bytesPerFrame = format.bytesPerFrame
        if (preparedFormat == null || bytesPerFrame <= 0) {
            output.put(inputBuffer)
            output.flip()
            return
        }
        val isFloat = format.encoding == C.ENCODING_PCM_FLOAT
        val swap = inputBuffer.order() != ByteOrder.LITTLE_ENDIAN
        val totalFrames = size / bytesPerFrame
        var frame = 0
        while (frame < totalFrames) {
            val frames = minOf(CHUNK_FRAMES, totalFrames - frame)
            val chunkStart = start + frame * bytesPerFrame
            val samples = frames * channelCount
            if (isFloat) {
                for (index in 0 until samples) {
                    val bits = inputBuffer.getInt(chunkStart + index * 4)
                    interleaved[index] = Float.fromBits(if (swap) Integer.reverseBytes(bits) else bits)
                }
            } else {
                for (index in 0 until samples) {
                    val raw = inputBuffer.getShort(chunkStart + index * 2)
                    interleaved[index] = (if (swap) java.lang.Short.reverseBytes(raw) else raw) / 32768f
                }
            }
            read.set(requested = frames)
            if (context.processSourceAudio(buffers, lanes, read)) {
                if (isFloat) {
                    for (index in 0 until samples) output.putFloat(interleaved[index])
                } else {
                    for (index in 0 until samples) {
                        output.putShort((interleaved[index] * 32768f).roundToInt().coerceIn(-32768, 32767).toShort())
                    }
                }
            } else {
                inputBuffer.limit(chunkStart + frames * bytesPerFrame)
                inputBuffer.position(chunkStart)
                output.put(inputBuffer)
                inputBuffer.limit(limit)
            }
            frame += frames
        }
        // A trailing partial frame cannot be processed; pass it through unchanged.
        val tail = start + totalFrames * bytesPerFrame
        if (tail < limit) {
            inputBuffer.position(tail)
            output.put(inputBuffer)
        }
        inputBuffer.position(limit)
        output.flip()
    }

    companion object {
        /** Frames per DSP call; buffers are sized from it, not from the decoder's output. */
        const val CHUNK_FRAMES = 1024

        fun isSupported(format: AudioFormat): Boolean =
            (format.encoding == C.ENCODING_PCM_16BIT || format.encoding == C.ENCODING_PCM_FLOAT) &&
                format.channelCount > 0 &&
                format.sampleRate >= DeepFilterProcessor.MINIMUM_SOURCE_RATE &&
                format.sampleRate <= DeepFilterProcessor.MAXIMUM_SOURCE_RATE
    }
}
