import AVFoundation
import Accelerate

final class NoiseReductionProcessor: @unchecked Sendable {

    private let fftSize = 1024
    private var noiseFloor: [Float]?
    private var profileFrameCount = 0
    private let profileLearnFrames = 30
    private var previousGains: [Float]?
    private let smoothingFactor: Float = 0.7

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
        noiseFloor = nil
        profileFrameCount = 0
        previousGains = nil
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
                processBlock(samples: samples.advanced(by: offset), setup: setup)
                offset += fftSize
            }
        }
    }

    private func processBlock(samples: UnsafeMutablePointer<Float>, setup: FFTSetup) {
        let n = fftSize
        let halfN = n / 2

        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)

        realp.withUnsafeMutableBufferPointer { realBuf in
            imagp.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)

                let input = UnsafeBufferPointer(start: samples, count: n)
                input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { ptr in
                    vDSP_ctoz(ptr, 2, &split, 1, vDSP_Length(halfN))
                }

                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }

        // Compute power spectrum (magnitude squared)
        var power = [Float](repeating: 0, count: halfN)
        realp.withUnsafeMutableBufferPointer { realBuf in
            imagp.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(halfN))
            }
        }

        // Learning phase: accumulate noise floor estimate
        if profileFrameCount < profileLearnFrames {
            if noiseFloor == nil {
                noiseFloor = [Float](repeating: 0, count: halfN)
            }
            // Use max of current estimate and new frame for robust floor
            for i in 0..<halfN {
                noiseFloor![i] = max(noiseFloor![i], power[i])
            }
            profileFrameCount += 1
            return
        }

        guard let noise = noiseFloor else { return }

        // Wiener gain: gain = max(power - noise, 0) / power
        // This is smoother than spectral subtraction
        var gains = [Float](repeating: 0, count: halfN)
        for i in 0..<halfN {
            if power[i] > 0.0001 {
                let clean = max(power[i] - noise[i] * 1.5, 0)
                gains[i] = sqrt(clean / power[i])
            } else {
                gains[i] = 0
            }
            // Floor the gain to avoid killing signal entirely
            gains[i] = max(gains[i], 0.1)
        }

        // Temporal smoothing: blend with previous frame's gains
        if let prev = previousGains {
            for i in 0..<halfN {
                gains[i] = smoothingFactor * prev[i] + (1.0 - smoothingFactor) * gains[i]
            }
        }
        previousGains = gains

        // Apply gains to spectrum
        vDSP_vmul(realp, 1, gains, 1, &realp, 1, vDSP_Length(halfN))
        vDSP_vmul(imagp, 1, gains, 1, &imagp, 1, vDSP_Length(halfN))

        // Inverse FFT
        var output = [Float](repeating: 0, count: n)

        realp.withUnsafeMutableBufferPointer { realBuf in
            imagp.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))

                output.withUnsafeMutableBufferPointer { outBuf in
                    outBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { ptr in
                        vDSP_ztoc(&split, 1, ptr, 2, vDSP_Length(halfN))
                    }
                }
            }
        }

        // Normalize IFFT output
        var scale = 1.0 / Float(2 * n)
        vDSP_vsmul(output, 1, &scale, &output, 1, vDSP_Length(n))

        // Write back
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
