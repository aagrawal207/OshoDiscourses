import AVFoundation
import Accelerate

final class VoiceFilterProcessor: @unchecked Sendable {

    private var highPassState = BiquadState()
    private var lowPassState = BiquadState()
    private var sampleRate: Double = 44100

    init() {}

    func reset() {
        highPassState = BiquadState()
        lowPassState = BiquadState()
    }

    func configure(sampleRate: Double) {
        self.sampleRate = sampleRate
        reset()
    }

    func process(buffer: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
        let bufferList = UnsafeMutableAudioBufferListPointer(buffer)
        for bufIdx in 0..<bufferList.count {
            guard let data = bufferList[bufIdx].mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            let count = Int(frameCount)

            // High-pass at 100Hz (removes hum)
            let hp = highPassCoeffs(frequency: 100, sampleRate: sampleRate)
            applyBiquad(samples: samples, count: count, coeffs: hp, state: &highPassState)

            // Low-pass at 7000Hz (removes hiss)
            let lp = lowPassCoeffs(frequency: 7000, sampleRate: sampleRate)
            applyBiquad(samples: samples, count: count, coeffs: lp, state: &lowPassState)
        }
    }

    // MARK: - Biquad

    private struct BiquadState {
        var x1: Float = 0
        var x2: Float = 0
        var y1: Float = 0
        var y2: Float = 0
    }

    private struct BiquadCoeffs {
        var b0: Float
        var b1: Float
        var b2: Float
        var a1: Float
        var a2: Float
    }

    private func highPassCoeffs(frequency: Double, sampleRate: Double) -> BiquadCoeffs {
        let w0 = 2.0 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2.0 * 0.707)
        let cosW0 = cos(w0)
        let a0 = 1.0 + alpha
        return BiquadCoeffs(
            b0: Float((1.0 + cosW0) / 2.0 / a0),
            b1: Float(-(1.0 + cosW0) / a0),
            b2: Float((1.0 + cosW0) / 2.0 / a0),
            a1: Float(-2.0 * cosW0 / a0),
            a2: Float((1.0 - alpha) / a0)
        )
    }

    private func lowPassCoeffs(frequency: Double, sampleRate: Double) -> BiquadCoeffs {
        let w0 = 2.0 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2.0 * 0.707)
        let cosW0 = cos(w0)
        let a0 = 1.0 + alpha
        return BiquadCoeffs(
            b0: Float((1.0 - cosW0) / 2.0 / a0),
            b1: Float((1.0 - cosW0) / a0),
            b2: Float((1.0 - cosW0) / 2.0 / a0),
            a1: Float(-2.0 * cosW0 / a0),
            a2: Float((1.0 - alpha) / a0)
        )
    }

    private func applyBiquad(samples: UnsafeMutablePointer<Float>, count: Int, coeffs: BiquadCoeffs, state: inout BiquadState) {
        for i in 0..<count {
            let x0 = samples[i]
            let y0 = coeffs.b0 * x0 + coeffs.b1 * state.x1 + coeffs.b2 * state.x2
                   - coeffs.a1 * state.y1 - coeffs.a2 * state.y2
            state.x2 = state.x1
            state.x1 = x0
            state.y2 = state.y1
            state.y1 = y0
            samples[i] = y0
        }
    }

    // MARK: - Audio Tap

    func createAudioMix(for track: AVAssetTrack, volumeBoost: Float = 1.0) -> AVAudioMix? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(self).toOpaque(),
            init: vfTapInit,
            finalize: vfTapFinalize,
            prepare: vfTapPrepare,
            unprepare: nil,
            process: vfTapProcess
        )

        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let audioTap = tap else { return nil }

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

private func vfTapInit(tap: MTAudioProcessingTap, clientInfo: UnsafeMutableRawPointer?, tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>) {
    tapStorageOut.pointee = clientInfo
}

private func vfTapFinalize(tap: MTAudioProcessingTap) {
    let storage = MTAudioProcessingTapGetStorage(tap)
    Unmanaged<VoiceFilterProcessor>.fromOpaque(storage).release()
}

private func vfTapPrepare(tap: MTAudioProcessingTap, maxFrames: CMItemCount, processingFormat: UnsafePointer<AudioStreamBasicDescription>) {
    let storage = MTAudioProcessingTapGetStorage(tap)
    let processor = Unmanaged<VoiceFilterProcessor>.fromOpaque(storage).takeUnretainedValue()
    let sr = processingFormat.pointee.mSampleRate
    processor.configure(sampleRate: sr)
}

private func vfTapProcess(tap: MTAudioProcessingTap, numberFrames: CMItemCount, flags: MTAudioProcessingTapFlags, bufferListInOut: UnsafeMutablePointer<AudioBufferList>, numberFramesOut: UnsafeMutablePointer<CMItemCount>, flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>) {
    let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
    guard status == noErr else { return }

    let storage = MTAudioProcessingTapGetStorage(tap)
    let processor = Unmanaged<VoiceFilterProcessor>.fromOpaque(storage).takeUnretainedValue()
    processor.process(buffer: bufferListInOut, frameCount: UInt32(numberFramesOut.pointee))
}
