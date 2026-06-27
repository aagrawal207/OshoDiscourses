import AVFoundation
import Accelerate

/// Runtime speech denoiser backed by RNNoise (xiph/rnnoise), a recurrent neural
/// network trained on speech + noise. It predicts a per-band gain mask every
/// 10ms frame — far smoother than spectral subtraction, with no musical noise.
///
/// RNNoise processes fixed 480-sample frames and expects samples in int16 range
/// (±32768), while the audio tap delivers variable-size buffers of ±1.0 float.
/// This class bridges both: it scales the domain and uses a per-channel FIFO
/// delay line (primed with one block of silence) so every callback emits exactly
/// as many samples as it received, with a constant ~10ms latency and no underflow.
///
/// All buffers are preallocated in `prepare` — the `process` path (which runs on
/// the realtime audio render thread) performs no allocation.
final class NoiseReductionProcessor: @unchecked Sendable {

    private let frameSize = Int(rnnoise_get_frame_size())   // 480

    private final class Channel {
        var state: OpaquePointer?           // DenoiseState*
        var inBuf: UnsafeMutablePointer<Float>
        var outBuf: UnsafeMutablePointer<Float>
        var frameIn: UnsafeMutablePointer<Float>
        var frameOut: UnsafeMutablePointer<Float>
        var inCount = 0
        var outCount = 0
        let capacity: Int

        init(capacity: Int, frameSize: Int) {
            self.capacity = capacity
            inBuf = .allocate(capacity: capacity)
            outBuf = .allocate(capacity: capacity)
            frameIn = .allocate(capacity: frameSize)
            frameOut = .allocate(capacity: frameSize)
            inBuf.initialize(repeating: 0, count: capacity)
            outBuf.initialize(repeating: 0, count: capacity)
            frameIn.initialize(repeating: 0, count: frameSize)
            frameOut.initialize(repeating: 0, count: frameSize)
            state = rnnoise_create(nil)
        }

        deinit {
            if let state { rnnoise_destroy(state) }
            inBuf.deallocate()
            outBuf.deallocate()
            frameIn.deallocate()
            frameOut.deallocate()
        }
    }

    private var channels: [Channel] = []
    private var maxFrames = 0
    private let lock = NSLock()

    init() {}

    deinit { teardown() }

    // MARK: - Lifecycle (called from tap prepare/unprepare)

    /// Allocate per-channel RNNoise state and FIFO buffers sized for this format.
    func prepare(channelCount: Int, maxFrames: Int) {
        lock.lock()
        defer { lock.unlock() }
        teardownLocked()
        self.maxFrames = maxFrames
        // FIFO capacity must hold: a sub-frame remainder (<480) plus one full tap
        // buffer, with headroom. maxFrames + 2*frameSize is comfortably safe.
        let capacity = maxFrames + 2 * frameSize + 16
        var built: [Channel] = []
        built.reserveCapacity(channelCount)
        for _ in 0..<max(channelCount, 1) {
            let ch = Channel(capacity: capacity, frameSize: frameSize)
            // Prime the output FIFO with one block of silence. This establishes a
            // constant `frameSize` latency and guarantees the emit step below can
            // always pull as many samples as came in (proven: in+out == frameSize
            // is invariant, and out-before-pop >= N+1 for any N).
            ch.outBuf.update(repeating: 0, count: frameSize)
            ch.outCount = frameSize
            built.append(ch)
        }
        channels = built
    }

    /// Reset filter memory without reallocating (e.g. on track change / toggle).
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        for ch in channels {
            if let s = ch.state { rnnoise_destroy(s) }
            ch.state = rnnoise_create(nil)
            ch.inCount = 0
            ch.outBuf.update(repeating: 0, count: ch.capacity)
            ch.outCount = frameSize       // re-prime latency block
        }
    }

    private func teardown() {
        lock.lock()
        defer { lock.unlock() }
        teardownLocked()
    }

    private func teardownLocked() {
        channels.removeAll()   // Channel.deinit frees C state + buffers
    }

    // MARK: - Realtime processing

    func process(buffer: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
        let n = Int(frameCount)
        guard n > 0 else { return }

        // Try-lock only: never block the audio thread. If prepare/reset is mid-flight
        // this callback passes audio through unchanged (one harmless frame).
        guard lock.try() else { return }
        defer { lock.unlock() }
        guard !channels.isEmpty else { return }

        let bufferList = UnsafeMutableAudioBufferListPointer(buffer)
        for bufIdx in 0..<bufferList.count {
            let audioBuffer = bufferList[bufIdx]
            // RNNoise is single-channel. Taps deliver deinterleaved float (one
            // channel per AudioBuffer). If a buffer is interleaved multichannel we
            // can't safely split it here, so pass it through untouched.
            let chans = Int(audioBuffer.mNumberChannels)
            guard chans == 1 else { continue }
            guard let raw = audioBuffer.mData else { continue }
            guard bufIdx < channels.count else { continue }
            let samples = raw.assumingMemoryBound(to: Float.self)
            processChannel(samples: samples, count: n, channel: channels[bufIdx])
        }
    }

    private func processChannel(samples: UnsafeMutablePointer<Float>, count n: Int, channel ch: Channel) {
        // Guard against an unexpectedly large buffer overrunning our FIFO.
        guard ch.inCount + n <= ch.capacity, n <= ch.capacity else { return }

        // 1. Append incoming samples to the input FIFO, scaled to int16 domain.
        var scaleUp: Float = 32768.0
        vDSP_vsmul(samples, 1, &scaleUp, ch.inBuf + ch.inCount, 1, vDSP_Length(n))
        ch.inCount += n

        // 2. Drain every complete 480-sample frame through RNNoise.
        var consumed = 0
        while ch.inCount - consumed >= frameSize {
            // out must hold a full frame; capacity guarantees it (see prepare).
            guard ch.outCount + frameSize <= ch.capacity else { break }
            // Copy frame to a dedicated input scratch (RNNoise reads `frameSize`).
            (ch.frameIn).update(from: ch.inBuf + consumed, count: frameSize)
            rnnoise_process_frame(ch.state, ch.frameOut, ch.frameIn)
            (ch.outBuf + ch.outCount).update(from: ch.frameOut, count: frameSize)
            ch.outCount += frameSize
            consumed += frameSize
        }

        // 3. Shift any unconsumed input remainder to the front of the FIFO.
        if consumed > 0 {
            let remaining = ch.inCount - consumed
            if remaining > 0 {
                memmove(ch.inBuf, ch.inBuf + consumed, remaining * MemoryLayout<Float>.size)
            }
            ch.inCount = remaining
        }

        // 4. Emit n samples from the output FIFO, scaled back to ±1.0.
        //    The priming block guarantees outCount >= n here.
        let emit = min(n, ch.outCount)
        var scaleDown: Float = 1.0 / 32768.0
        vDSP_vsmul(ch.outBuf, 1, &scaleDown, samples, 1, vDSP_Length(emit))
        if emit < n {
            // Should not happen given the invariant; fill any shortfall with silence.
            (samples + emit).update(repeating: 0, count: n - emit)
        }

        // 5. Shift the consumed output out of the FIFO.
        let leftover = ch.outCount - emit
        if leftover > 0 {
            memmove(ch.outBuf, ch.outBuf + emit, leftover * MemoryLayout<Float>.size)
        }
        ch.outCount = leftover
    }

    // MARK: - Audio Tap

    func createAudioMix(for track: AVAssetTrack, volumeBoost: Float = 1.0) -> AVAudioMix? {
        // +1 retain that tapFinalize will balance with .release(). Held in a local
        // so we can release it ourselves if the tap is never created (see below).
        let retained = Unmanaged.passRetained(self)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: retained.toOpaque(),
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: tapUnprepare,
            process: tapProcess
        )

        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let audioTap = tap else {
            // No tap was created, so tapFinalize will never run — balance the
            // retain here to avoid leaking self.
            retained.release()
            return nil
        }

        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = audioTap
        if volumeBoost > 1.0 {
            params.setVolume(volumeBoost, at: .zero)
        }

        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }
}

// MARK: - MTAudioProcessingTap Callbacks

private func tapInit(tap: MTAudioProcessingTap, clientInfo: UnsafeMutableRawPointer?, tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>) {
    tapStorageOut.pointee = clientInfo
}

private func tapFinalize(tap: MTAudioProcessingTap) {
    let storage = MTAudioProcessingTapGetStorage(tap)
    Unmanaged<NoiseReductionProcessor>.fromOpaque(storage).release()
}

private func tapPrepare(tap: MTAudioProcessingTap, maxFrames: CMItemCount, processingFormat: UnsafePointer<AudioStreamBasicDescription>) {
    let storage = MTAudioProcessingTapGetStorage(tap)
    let processor = Unmanaged<NoiseReductionProcessor>.fromOpaque(storage).takeUnretainedValue()
    let asbd = processingFormat.pointee
    processor.prepare(channelCount: Int(asbd.mChannelsPerFrame), maxFrames: Int(maxFrames))
}

private func tapUnprepare(tap: MTAudioProcessingTap) {
    let storage = MTAudioProcessingTapGetStorage(tap)
    let processor = Unmanaged<NoiseReductionProcessor>.fromOpaque(storage).takeUnretainedValue()
    processor.reset()
}

private func tapProcess(tap: MTAudioProcessingTap, numberFrames: CMItemCount, flags: MTAudioProcessingTapFlags, bufferListInOut: UnsafeMutablePointer<AudioBufferList>, numberFramesOut: UnsafeMutablePointer<CMItemCount>, flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>) {
    let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
    guard status == noErr else { return }

    let storage = MTAudioProcessingTapGetStorage(tap)
    let processor = Unmanaged<NoiseReductionProcessor>.fromOpaque(storage).takeUnretainedValue()
    processor.process(buffer: bufferListInOut, frameCount: UInt32(numberFramesOut.pointee))
}
