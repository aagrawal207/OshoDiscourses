import AVFoundation
import Accelerate

final class NoiseReductionProcessor: @unchecked Sendable {

    private var noiseFloor: [Float]?
    private var profileFrameCount = 0
    private let profileLearnFrames = 15
    private var previousGains: [Float]?
    private let smoothingFactor: Float = 0.7

    init() {}

    func reset() {
        noiseFloor = nil
        profileFrameCount = 0
        previousGains = nil
    }

    func process(buffer: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
        let bufferList = UnsafeMutableAudioBufferListPointer(buffer)
        for bufIdx in 0..<bufferList.count {
            guard let data = bufferList[bufIdx].mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            let count = Int(frameCount)
            processBuffer(samples: samples, count: count)
        }
    }

    private func processBuffer(samples: UnsafeMutablePointer<Float>, count: Int) {
        // Find the largest power-of-2 that fits
        let log2n = vDSP_Length(floor(log2(Double(count))))
        let n = 1 << Int(log2n)
        guard n >= 64 else { return }
        let halfN = n / 2

        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return }
        defer { vDSP_destroy_fftsetup(setup) }

        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)

        // Forward FFT
        realp.withUnsafeMutableBufferPointer { realBuf in
            imagp.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                UnsafePointer(samples).withMemoryRebound(to: DSPComplex.self, capacity: halfN) { ptr in
                    vDSP_ctoz(ptr, 2, &split, 1, vDSP_Length(halfN))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }

        // Power spectrum
        var power = [Float](repeating: 0, count: halfN)
        realp.withUnsafeMutableBufferPointer { realBuf in
            imagp.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(halfN))
            }
        }

        // Noise profile learning
        if profileFrameCount < profileLearnFrames {
            if noiseFloor == nil || noiseFloor!.count != halfN {
                noiseFloor = [Float](repeating: 0, count: halfN)
                previousGains = nil
            }
            vDSP_vadd(noiseFloor!, 1, power, 1, &noiseFloor!, 1, vDSP_Length(halfN))
            profileFrameCount += 1
            if profileFrameCount == profileLearnFrames {
                var divisor = Float(profileLearnFrames)
                vDSP_vsdiv(noiseFloor!, 1, &divisor, &noiseFloor!, 1, vDSP_Length(halfN))
            }
            return
        }

        guard let noise = noiseFloor, noise.count == halfN else { return }

        // Wiener gain
        var gains = [Float](repeating: 0, count: halfN)
        for i in 0..<halfN {
            let signalPower = power[i]
            let noisePower = noise[i]
            if signalPower > noisePower * 0.5 {
                gains[i] = max((signalPower - noisePower) / signalPower, 0.12)
            } else {
                gains[i] = 0.12
            }
        }

        // Temporal smoothing between successive buffers
        if let prev = previousGains, prev.count == halfN {
            for i in 0..<halfN {
                gains[i] = smoothingFactor * prev[i] + (1.0 - smoothingFactor) * gains[i]
            }
        }
        previousGains = gains

        // Apply gains
        vDSP_vmul(realp, 1, gains, 1, &realp, 1, vDSP_Length(halfN))
        vDSP_vmul(imagp, 1, gains, 1, &imagp, 1, vDSP_Length(halfN))

        // Inverse FFT
        realp.withUnsafeMutableBufferPointer { realBuf in
            imagp.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                UnsafeMutablePointer(samples).withMemoryRebound(to: DSPComplex.self, capacity: halfN) { ptr in
                    vDSP_ztoc(&split, 1, ptr, 2, vDSP_Length(halfN))
                }
            }
        }

        // Normalize IFFT
        var scale = 1.0 / Float(2 * n)
        vDSP_vsmul(samples, 1, &scale, samples, 1, vDSP_Length(n))
    }

    // MARK: - Audio Tap

    func createAudioMix(for track: AVAssetTrack, volumeBoost: Float = 1.0) -> AVAudioMix? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(self).toOpaque(),
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: nil,
            process: tapProcess
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
    processor.reset()
}

private func tapProcess(tap: MTAudioProcessingTap, numberFrames: CMItemCount, flags: MTAudioProcessingTapFlags, bufferListInOut: UnsafeMutablePointer<AudioBufferList>, numberFramesOut: UnsafeMutablePointer<CMItemCount>, flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>) {
    let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
    guard status == noErr else { return }

    let storage = MTAudioProcessingTapGetStorage(tap)
    let processor = Unmanaged<NoiseReductionProcessor>.fromOpaque(storage).takeUnretainedValue()
    processor.process(buffer: bufferListInOut, frameCount: UInt32(numberFramesOut.pointee))
}
