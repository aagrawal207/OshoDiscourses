import AVFoundation
import Accelerate

/// Runtime speech denoiser backed by RNNoise (xiph/rnnoise), a recurrent neural
/// network trained on speech + noise. It predicts a per-band gain mask every
/// 10ms frame — far smoother than spectral subtraction, with no musical noise.
///
/// RNNoise processes fixed 480-sample frames and expects samples in int16 range
/// (±32768), while the audio tap delivers variable-size buffers of ±1.0 float.
/// This class bridges both: it scales the domain and uses a per-channel FIFO
/// delay line so every callback emits exactly as many samples as it received.
/// It also hosts the beta Cadence filter, which uses classical DSP rather than
/// RNNoise so the two approaches can be compared on the same recordings, and
/// delegates the DeepFilterNet mode to `DeepFilterProcessor` (a native 48 kHz
/// model with its own streaming state and no dry/wet blend).
///
/// All buffers are preallocated in `prepare` — the `process` path (which runs on
/// the realtime audio render thread) performs no allocation.
final class NoiseReductionProcessor: @unchecked Sendable {

    private let frameSize = Int(rnnoise_get_frame_size())   // 480

    private var mode: NoiseReductionMode = .rnnoise
    private var wetMix: Float = 0.5
    private var intensity: Float = 0.7
    /// DeepFilterNet's strength control: a cap on attenuation in dB.
    private var attenuationLimitDb: Float = 100

    /// Native DeepFilterNet runtime. Owned here so the tap has a single host,
    /// but it keeps its own state and lock — it is not driven by the RNNoise
    /// FIFOs below.
    let deepFilter = DeepFilterProcessor()

    private struct Biquad {
        var b0: Float = 1
        var b1: Float = 0
        var b2: Float = 0
        var a1: Float = 0
        var a2: Float = 0
        var z1: Float = 0
        var z2: Float = 0

        mutating func process(_ input: Float) -> Float {
            let output = b0 * input + z1
            z1 = b1 * input - a1 * output + z2
            z2 = b2 * input - a2 * output
            return output
        }

        static func notch(frequency: Double, sampleRate: Double, q: Double) -> Self {
            let omega = 2 * Double.pi * frequency / sampleRate
            let alpha = sin(omega) / (2 * q)
            let a0 = 1 + alpha
            return Self(
                b0: Float(1 / a0),
                b1: Float(-2 * cos(omega) / a0),
                b2: Float(1 / a0),
                a1: Float(-2 * cos(omega) / a0),
                a2: Float((1 - alpha) / a0)
            )
        }

        static func highPass(frequency: Double, sampleRate: Double) -> Self {
            let omega = 2 * Double.pi * frequency / sampleRate
            let alpha = sin(omega) / (2 * 0.707)
            let cosOmega = cos(omega)
            let a0 = 1 + alpha
            return Self(
                b0: Float((1 + cosOmega) / 2 / a0),
                b1: Float(-(1 + cosOmega) / a0),
                b2: Float((1 + cosOmega) / 2 / a0),
                a1: Float(-2 * cosOmega / a0),
                a2: Float((1 - alpha) / a0)
            )
        }

        static func lowPass(frequency: Double, sampleRate: Double) -> Self {
            let omega = 2 * Double.pi * frequency / sampleRate
            let alpha = sin(omega) / (2 * 0.707)
            let cosOmega = cos(omega)
            let a0 = 1 + alpha
            return Self(
                b0: Float((1 - cosOmega) / 2 / a0),
                b1: Float((1 - cosOmega) / a0),
                b2: Float((1 - cosOmega) / 2 / a0),
                a1: Float(-2 * cosOmega / a0),
                a2: Float((1 - alpha) / a0)
            )
        }
    }

    private final class Channel {
        var state: OpaquePointer?           // DenoiseState*
        var inBuf: UnsafeMutablePointer<Float>
        var outBuf: UnsafeMutablePointer<Float>   // wet (denoised) FIFO
        var dryBuf: UnsafeMutablePointer<Float>   // dry FIFO, lockstep with outBuf
        var frameIn: UnsafeMutablePointer<Float>
        var frameOut: UnsafeMutablePointer<Float>
        var previousDryFrame: UnsafeMutablePointer<Float>
        var inCount = 0
        var outCount = 0
        let capacity: Int
        var sampleRate: Double = 48_000
        var highPass = Biquad()
        var notch50 = Biquad()
        var notch60 = Biquad()
        var notch100 = Biquad()
        var notch120 = Biquad()
        var hissLowPass = Biquad()
        var envelope: Float = 0
        var quietSamples = 0
        var gateGain: Float = 1

        init(capacity: Int, frameSize: Int) {
            self.capacity = capacity
            inBuf = .allocate(capacity: capacity)
            outBuf = .allocate(capacity: capacity)
            dryBuf = .allocate(capacity: capacity)
            frameIn = .allocate(capacity: frameSize)
            frameOut = .allocate(capacity: frameSize)
            previousDryFrame = .allocate(capacity: frameSize)
            inBuf.initialize(repeating: 0, count: capacity)
            outBuf.initialize(repeating: 0, count: capacity)
            dryBuf.initialize(repeating: 0, count: capacity)
            frameIn.initialize(repeating: 0, count: frameSize)
            frameOut.initialize(repeating: 0, count: frameSize)
            previousDryFrame.initialize(repeating: 0, count: frameSize)
            state = rnnoise_create(nil)
        }

        func configureArchive(sampleRate: Double, intensity: Float) {
            self.sampleRate = sampleRate
            highPass = .highPass(frequency: 32, sampleRate: sampleRate)
            notch50 = .notch(frequency: 50, sampleRate: sampleRate, q: 35)
            notch60 = .notch(frequency: 60, sampleRate: sampleRate, q: 35)
            notch100 = .notch(frequency: 100, sampleRate: sampleRate, q: 42)
            notch120 = .notch(frequency: 120, sampleRate: sampleRate, q: 42)
            let cutoff = 14_000 - 3_500 * Double(intensity)
            hissLowPass = .lowPass(
                frequency: min(cutoff, sampleRate * 0.45),
                sampleRate: sampleRate
            )
            envelope = 0
            quietSamples = 0
            gateGain = 1
        }

        deinit {
            if let state { rnnoise_destroy(state) }
            inBuf.deallocate()
            outBuf.deallocate()
            dryBuf.deallocate()
            frameIn.deallocate()
            frameOut.deallocate()
            previousDryFrame.deallocate()
        }
    }

    private var channels: [Channel] = []
    private var maxFrames = 0
    private let lock = NSLock()

    init() {}

    deinit { teardown() }

    // MARK: - Lifecycle (called from tap prepare/unprepare)

    func configure(
        mode: NoiseReductionMode,
        wetMix: Float,
        intensity: Float,
        attenuationLimitDb: Float,
        voiceFocus: VoiceFocusPreset
    ) {
        lock.lock()
        let modeChanged = self.mode != mode
        self.mode = mode
        self.wetMix = min(max(wetMix, 0), 1)
        self.intensity = min(max(intensity, 0), 1)
        self.attenuationLimitDb = max(attenuationLimitDb, 0)
        for ch in channels {
            ch.configureArchive(sampleRate: ch.sampleRate, intensity: self.intensity)
            if modeChanged {
                resetRNNoiseChannel(ch)
            }
        }
        let format = channels.first.map { ($0.sampleRate, self.maxFrames, channels.count) }
        // Capture before unlocking: reading these properties afterwards would be
        // an unsynchronized read from whatever thread called configure.
        let attenuation = self.attenuationLimitDb
        lock.unlock()

        // DeepFilterNet keeps its own state, so drive it outside the lock.
        deepFilter.setAttenuationLimit(attenuation)
        deepFilter.setVoiceFocus(voiceFocus)
        if mode == .deepFilterNet {
            if let (sampleRate, maxFrames, channelCount) = format, maxFrames > 0 {
                deepFilter.activate(
                    channelCount: channelCount,
                    maxFrames: maxFrames,
                    sampleRate: sampleRate
                )
            }
        } else if modeChanged {
            // Leaving DeepFilterNet: clear streaming state but keep the loaded
            // model so switching back does not pay the load cost again.
            deepFilter.reset()
        }
    }

    /// Allocate per-channel processor state and FIFO buffers sized for this format.
    func prepare(channelCount: Int, maxFrames: Int, sampleRate: Double) {
        lock.lock()
        teardownLocked()
        self.maxFrames = maxFrames
        // FIFO capacity must hold: a sub-frame remainder (<480) plus one full tap
        // buffer, with headroom. maxFrames + 2*frameSize is comfortably safe.
        let capacity = maxFrames + 2 * frameSize + 16
        var built: [Channel] = []
        built.reserveCapacity(channelCount)
        for _ in 0..<max(channelCount, 1) {
            let ch = Channel(capacity: capacity, frameSize: frameSize)
            ch.configureArchive(sampleRate: sampleRate, intensity: intensity)
            // Prime both FIFOs with one block of silence. This establishes a
            // constant `frameSize` latency and guarantees the emit step below can
            // always pull as many samples as came in (proven: in+out == frameSize
            // is invariant, and out-before-pop >= N+1 for any N). The dry FIFO is
            // primed identically so wet and dry stay sample-aligned for blending.
            ch.outBuf.update(repeating: 0, count: frameSize)
            ch.dryBuf.update(repeating: 0, count: frameSize)
            ch.outCount = frameSize
            built.append(ch)
        }
        channels = built
        let activeMode = mode
        lock.unlock()

        if activeMode == .deepFilterNet {
            deepFilter.activate(
                channelCount: max(channelCount, 1),
                maxFrames: maxFrames,
                sampleRate: sampleRate
            )
        }
    }

    /// Reset filter memory without reallocating (e.g. on track change / toggle).
    func reset() {
        lock.lock()
        for ch in channels {
            resetRNNoiseChannel(ch)
            ch.configureArchive(sampleRate: ch.sampleRate, intensity: intensity)
        }
        lock.unlock()
        deepFilter.reset()
    }

    private func resetRNNoiseChannel(_ ch: Channel) {
        if let state = ch.state { rnnoise_destroy(state) }
        ch.state = rnnoise_create(nil)
        ch.inCount = 0
        ch.outBuf.update(repeating: 0, count: ch.capacity)
        ch.dryBuf.update(repeating: 0, count: ch.capacity)
        ch.previousDryFrame.update(repeating: 0, count: frameSize)
        ch.outCount = frameSize
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
            switch mode {
            case .rnnoise:
                processRNNoise(samples: samples, count: n, channel: channels[bufIdx])
            case .cadence:
                processCadence(samples: samples, count: n, channel: channels[bufIdx])
            case .deepFilterNet:
                // Owns its own state and lock. A false return means it is not
                // ready (still loading, or unavailable) and left the audio
                // untouched, which is the correct passthrough behaviour.
                deepFilter.process(samples: samples, count: n, channelIndex: bufIdx)
            }
        }
    }

    private func processRNNoise(samples: UnsafeMutablePointer<Float>, count n: Int, channel ch: Channel) {
        // Guard against an unexpectedly large buffer overrunning our FIFO.
        guard ch.inCount + n <= ch.capacity, n <= ch.capacity else { return }

        // 1. Append incoming samples to the input FIFO, scaled to int16 domain.
        var scaleUp: Float = 32768.0
        vDSP_vsmul(samples, 1, &scaleUp, ch.inBuf + ch.inCount, 1, vDSP_Length(n))
        ch.inCount += n

        // 2. Drain every complete 480-sample frame through RNNoise. For each frame
        //    RNNoise's synthesis output is one frame behind its input, so pair it
        //    with the previous dry frame rather than the current one. Mixing the
        //    current dry frame caused comb-like coloration, especially on Strong.
        var consumed = 0
        while ch.inCount - consumed >= frameSize {
            // out must hold a full frame; capacity guarantees it (see prepare).
            guard ch.outCount + frameSize <= ch.capacity else { break }
            // Copy frame to a dedicated input scratch (RNNoise reads `frameSize`).
            (ch.frameIn).update(from: ch.inBuf + consumed, count: frameSize)
            rnnoise_process_frame(ch.state, ch.frameOut, ch.frameIn)
            (ch.outBuf + ch.outCount).update(from: ch.frameOut, count: frameSize)
            (ch.dryBuf + ch.outCount).update(from: ch.previousDryFrame, count: frameSize)
            ch.previousDryFrame.update(from: ch.frameIn, count: frameSize)
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

        // 4. Emit n samples: blend wet (denoised) and dry (original) per the mix,
        //    then scale back to ±1.0. wetMix below 1.0 preserves voice clarity by
        //    flooring how much any band — including over-suppressed consonants —
        //    can be attenuated. The priming block guarantees outCount >= n.
        let emit = min(n, ch.outCount)
        let wet = wetMix
        let dry = 1.0 - wetMix
        let inv: Float = 1.0 / 32768.0
        var wetScale = wet * inv
        var dryScale = dry * inv
        // samples = outBuf*wetScale, then samples = dryBuf*dryScale + samples.
        // (vDSP_vsma: D[i] = A[i]*scalar + C[i] — vector × scalar + vector)
        vDSP_vsmul(ch.outBuf, 1, &wetScale, samples, 1, vDSP_Length(emit))
        vDSP_vsma(ch.dryBuf, 1, &dryScale, samples, 1, samples, 1, vDSP_Length(emit))
        if emit < n {
            // Should not happen given the invariant; fill any shortfall with silence.
            (samples + emit).update(repeating: 0, count: n - emit)
        }

        // 5. Shift the consumed output out of both FIFOs in lockstep.
        let leftover = ch.outCount - emit
        if leftover > 0 {
            memmove(ch.outBuf, ch.outBuf + emit, leftover * MemoryLayout<Float>.size)
            memmove(ch.dryBuf, ch.dryBuf + emit, leftover * MemoryLayout<Float>.size)
        }
        ch.outCount = leftover
    }

    private func processCadence(samples: UnsafeMutablePointer<Float>, count: Int, channel ch: Channel) {
        let sampleRate = Float(ch.sampleRate)
        let envelopeAttack = exp(-1 / (0.008 * sampleRate))
        let envelopeRelease = exp(-1 / (0.22 * sampleRate))
        let gateOpen = exp(-1 / (0.006 * sampleRate))
        let gateClose = exp(-1 / (0.35 * sampleRate))
        let quietHold = Int(sampleRate * (0.22 + 0.18 * (1 - intensity)))
        let quietThreshold: Float = 0.009
        let quietGain = 1 - 0.82 * intensity

        for index in 0..<count {
            let dry = samples[index]
            var filtered = ch.highPass.process(dry)
            filtered = ch.notch50.process(filtered)
            filtered = ch.notch60.process(filtered)
            filtered = ch.notch100.process(filtered)
            filtered = ch.notch120.process(filtered)
            filtered = ch.hissLowPass.process(filtered)

            let level = abs(filtered)
            let envelopeCoefficient = level > ch.envelope ? envelopeAttack : envelopeRelease
            ch.envelope = level + envelopeCoefficient * (ch.envelope - level)

            if ch.envelope < quietThreshold {
                ch.quietSamples += 1
            } else {
                ch.quietSamples = 0
            }

            let targetGain: Float = ch.quietSamples >= quietHold ? quietGain : 1
            let gateCoefficient = targetGain > ch.gateGain ? gateOpen : gateClose
            ch.gateGain = targetGain + gateCoefficient * (ch.gateGain - targetGain)

            let processed = filtered * ch.gateGain
            samples[index] = dry + intensity * (processed - dry)
        }
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
    processor.prepare(
        channelCount: Int(asbd.mChannelsPerFrame),
        maxFrames: Int(maxFrames),
        sampleRate: asbd.mSampleRate
    )
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
