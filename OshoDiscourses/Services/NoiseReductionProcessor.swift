import AVFoundation
import Accelerate

final class NoiseReductionProcessor: @unchecked Sendable {

    private let fftSize = 2048
    private let hopSize = 512
    private var noiseProfile: [Float]?
    private var profileFrameCount = 0
    private let profileLearnFrames = 20
    private let reductionStrength: Float = 0.7

    private var fftSetup: FFTSetup?
    private let log2n: vDSP_Length

    init() {
        log2n = vDSP_Length(log2(Double(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    }

    deinit {
        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
        }
    }

    func reset() {
        noiseProfile = nil
        profileFrameCount = 0
    }

    func process(buffer: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
        guard let setup = fftSetup else { return }

        let bufferList = UnsafeMutableAudioBufferListPointer(buffer)
        for bufIdx in 0..<bufferList.count {
            guard let data = bufferList[bufIdx].mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            let count = Int(frameCount)

            var offset = 0
            while offset + fftSize <= count {
                processFrame(samples: samples.advanced(by: offset), setup: setup)
                offset += hopSize
            }
        }
    }

    private func processFrame(samples: UnsafeMutablePointer<Float>, setup: FFTSetup) {
        let n = fftSize
        let halfN = n / 2

        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))

        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))

        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)

        realp.withUnsafeMutableBufferPointer { realBuf in
            imagp.withUnsafeMutableBufferPointer { imagBuf in
                var splitComplex = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)

                windowed.withUnsafeBufferPointer { ptr in
                    ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(halfN))
                    }
                }

                vDSP_fft_zrip(setup, &splitComplex, 1, self.log2n, FFTDirection(kFFTDirection_Forward))
            }
        }

        var magnitudes = [Float](repeating: 0, count: halfN)
        realp.withUnsafeMutableBufferPointer { realBuf in
            imagp.withUnsafeMutableBufferPointer { imagBuf in
                var splitComplex = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                vDSP_zvabs(&splitComplex, 1, &magnitudes, 1, vDSP_Length(halfN))
            }
        }

        if profileFrameCount < profileLearnFrames {
            if noiseProfile == nil {
                noiseProfile = [Float](repeating: 0, count: halfN)
            }
            vDSP_vadd(noiseProfile!, 1, magnitudes, 1, &noiseProfile!, 1, vDSP_Length(halfN))
            profileFrameCount += 1

            if profileFrameCount == profileLearnFrames {
                var divisor = Float(profileLearnFrames)
                vDSP_vsdiv(noiseProfile!, 1, &divisor, &noiseProfile!, 1, vDSP_Length(halfN))
            }
            return
        }

        guard let profile = noiseProfile else { return }

        var scaledProfile = [Float](repeating: 0, count: halfN)
        var strength = reductionStrength
        vDSP_vsmul(profile, 1, &strength, &scaledProfile, 1, vDSP_Length(halfN))

        var subtracted = [Float](repeating: 0, count: halfN)
        vDSP_vsub(scaledProfile, 1, magnitudes, 1, &subtracted, 1, vDSP_Length(halfN))

        var floor: Float = 0.001
        vDSP_vthres(subtracted, 1, &floor, &subtracted, 1, vDSP_Length(halfN))

        var gains = [Float](repeating: 0, count: halfN)
        for i in 0..<halfN {
            gains[i] = magnitudes[i] > 0.001 ? subtracted[i] / magnitudes[i] : 1.0
        }

        vDSP_vmul(realp, 1, gains, 1, &realp, 1, vDSP_Length(halfN))
        vDSP_vmul(imagp, 1, gains, 1, &imagp, 1, vDSP_Length(halfN))

        var output = [Float](repeating: 0, count: n)

        realp.withUnsafeMutableBufferPointer { realBuf in
            imagp.withUnsafeMutableBufferPointer { imagBuf in
                var splitComplex = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)

                vDSP_fft_zrip(setup, &splitComplex, 1, self.log2n, FFTDirection(kFFTDirection_Inverse))

                output.withUnsafeMutableBufferPointer { outBuf in
                    outBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
                        vDSP_ztoc(&splitComplex, 1, complexPtr, 2, vDSP_Length(halfN))
                    }
                }
            }
        }

        var scale = 1.0 / Float(2 * n)
        vDSP_vsmul(output, 1, &scale, &output, 1, vDSP_Length(n))
        vDSP_vmul(output, 1, window, 1, &output, 1, vDSP_Length(n))

        samples.update(from: output, count: n)
    }

    // MARK: - Audio Tap

    func createAudioMix(for track: AVAssetTrack) -> AVAudioMix? {

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
