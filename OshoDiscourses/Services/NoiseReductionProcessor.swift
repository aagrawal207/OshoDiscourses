import AVFoundation
import Accelerate

final class NoiseReductionProcessor: @unchecked Sendable {

    private let fftSize = 2048
    private let hopSize = 1024
    private var noiseFloor: [Float]?
    private var profileFrameCount = 0
    private let profileLearnFrames = 15
    private var previousGains: [Float]?
    private let smoothingFactor: Float = 0.6
    private var window: [Float]
    private var overlapBuffer: [Float]

    private var fftSetup: FFTSetup?
    private let log2n: vDSP_Length

    init() {
        let n = 2048
        log2n = vDSP_Length(log2(Double(n)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        overlapBuffer = [Float](repeating: 0, count: n)
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
        overlapBuffer = [Float](repeating: 0, count: fftSize)
    }

    func process(buffer: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
        guard let setup = fftSetup else { return }

        let bufferList = UnsafeMutableAudioBufferListPointer(buffer)
        for bufIdx in 0..<bufferList.count {
            guard let data = bufferList[bufIdx].mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            let count = Int(frameCount)
            processChannel(samples: samples, count: count, setup: setup)
        }
    }

    private func processChannel(samples: UnsafeMutablePointer<Float>, count: Int, setup: FFTSetup) {
        let n = fftSize
        let hop = hopSize

        var output = [Float](repeating: 0, count: count)

        var offset = 0
        while offset + n <= count {
            let frame = processFrame(samples: samples.advanced(by: offset), setup: setup)
            // Overlap-add: add the previous overlap tail, store new tail
            for i in 0..<hop {
                output[offset + i] = overlapBuffer[i] + frame[i]
            }
            // Store the second half for next overlap
            for i in 0..<hop {
                overlapBuffer[i] = frame[hop + i]
            }
            offset += hop
        }

        // Copy remaining samples unchanged
        for i in offset..<count {
            output[i] = samples[i]
        }

        // Write back
        samples.update(from: output, count: count)
    }

    private func processFrame(samples: UnsafePointer<Float>, setup: FFTSetup) -> [Float] {
        let n = fftSize
        let halfN = n / 2

        // Apply window
        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))

        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)

        realp.withUnsafeMutableBufferPointer { realBuf in
            imagp.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                windowed.withUnsafeBufferPointer { ptr in
                    ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cPtr in
                        vDSP_ctoz(cPtr, 2, &split, 1, vDSP_Length(halfN))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }

        // Compute power spectrum
        var power = [Float](repeating: 0, count: halfN)
        realp.withUnsafeMutableBufferPointer { realBuf in
            imagp.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(halfN))
            }
        }

        // Learning phase: accumulate average noise floor
        if profileFrameCount < profileLearnFrames {
            if noiseFloor == nil {
                noiseFloor = [Float](repeating: 0, count: halfN)
            }
            vDSP_vadd(noiseFloor!, 1, power, 1, &noiseFloor!, 1, vDSP_Length(halfN))
            profileFrameCount += 1

            if profileFrameCount == profileLearnFrames {
                var divisor = Float(profileLearnFrames)
                vDSP_vsdiv(noiseFloor!, 1, &divisor, &noiseFloor!, 1, vDSP_Length(halfN))
            }
            // During learning, return windowed input as-is (for proper OLA envelope)
            var result = [Float](repeating: 0, count: n)
            vDSP_vmul(samples, 1, window, 1, &result, 1, vDSP_Length(n))
            return result
        }

        guard let noise = noiseFloor else {
            var result = [Float](repeating: 0, count: n)
            vDSP_vmul(samples, 1, window, 1, &result, 1, vDSP_Length(n))
            return result
        }

        // Wiener gain: gain = (power - noise) / power, clamped
        var gains = [Float](repeating: 0, count: halfN)
        for i in 0..<halfN {
            if power[i] > 1e-10 {
                let snr = power[i] / (noise[i] + 1e-10)
                gains[i] = max(1.0 - 1.0 / snr, 0.08)
            } else {
                gains[i] = 0.08
            }
        }

        // Temporal smoothing
        if let prev = previousGains {
            for i in 0..<halfN {
                gains[i] = smoothingFactor * prev[i] + (1.0 - smoothingFactor) * gains[i]
            }
        }
        previousGains = gains

        // Apply gains
        vDSP_vmul(realp, 1, gains, 1, &realp, 1, vDSP_Length(halfN))
        vDSP_vmul(imagp, 1, gains, 1, &imagp, 1, vDSP_Length(halfN))

        // Inverse FFT
        var output = [Float](repeating: 0, count: n)
        realp.withUnsafeMutableBufferPointer { realBuf in
            imagp.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                output.withUnsafeMutableBufferPointer { outBuf in
                    outBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cPtr in
                        vDSP_ztoc(&split, 1, cPtr, 2, vDSP_Length(halfN))
                    }
                }
            }
        }

        // Normalize and apply synthesis window
        var scale = 1.0 / Float(2 * n)
        vDSP_vsmul(output, 1, &scale, &output, 1, vDSP_Length(n))
        vDSP_vmul(output, 1, window, 1, &output, 1, vDSP_Length(n))

        return output
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
