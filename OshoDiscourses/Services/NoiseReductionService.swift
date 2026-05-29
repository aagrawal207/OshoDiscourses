import Accelerate
import AVFoundation
import Foundation

actor NoiseReductionService {

    static let shared = NoiseReductionService()

    private let fftSize = 2048
    private let hopSize = 512
    private let noiseEstimateSeconds: Double = 1.5
    private let subtractFactor: Float = 1.8
    private let spectralFloor: Float = 0.02

    enum NoiseReductionError: Error {
        case cannotReadFile
        case cannotWriteFile
        case processingFailed
    }

    func process(input: URL, output: URL) async throws {
        let inputFile = try AVAudioFile(forReading: input)
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFile.fileFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NoiseReductionError.cannotReadFile
        }

        let frameCount = AVAudioFrameCount(inputFile.length)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frameCount) else {
            throw NoiseReductionError.cannotReadFile
        }

        if inputFile.processingFormat.channelCount != 1 || inputFile.processingFormat.commonFormat != .pcmFormatFloat32 {
            guard let converter = AVAudioConverter(from: inputFile.processingFormat, to: monoFormat) else {
                throw NoiseReductionError.cannotReadFile
            }
            var error: NSError?
            converter.convert(to: inputBuffer, error: &error) { inNumPackets, outStatus in
                let readBuffer = AVAudioPCMBuffer(pcmFormat: self.inputFile_processingFormat(inputFile), frameCapacity: inNumPackets)!
                do {
                    try inputFile.read(into: readBuffer)
                    outStatus.pointee = .haveData
                } catch {
                    outStatus.pointee = .endOfStream
                }
                return readBuffer
            }
            if let error { throw error }
        } else {
            try inputFile.read(into: inputBuffer)
        }

        guard let samples = inputBuffer.floatChannelData?[0] else {
            throw NoiseReductionError.cannotReadFile
        }
        let sampleCount = Int(inputBuffer.frameLength)
        guard sampleCount > fftSize else { throw NoiseReductionError.processingFailed }

        let processedSamples = try spectralSubtraction(
            samples: samples,
            count: sampleCount,
            sampleRate: Float(monoFormat.sampleRate)
        )
        defer { processedSamples.deallocate() }

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(sampleCount)) else {
            throw NoiseReductionError.cannotWriteFile
        }
        outputBuffer.frameLength = AVAudioFrameCount(sampleCount)
        memcpy(outputBuffer.floatChannelData![0], processedSamples, sampleCount * MemoryLayout<Float>.size)

        let outputFile = try AVAudioFile(
            forWriting: output,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: monoFormat.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                AVEncoderBitRateKey: 128_000
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try outputFile.write(from: outputBuffer)
    }

    private nonisolated func inputFile_processingFormat(_ file: AVAudioFile) -> AVAudioFormat {
        file.processingFormat
    }

    // MARK: - Spectral Subtraction

    private func spectralSubtraction(
        samples: UnsafePointer<Float>,
        count: Int,
        sampleRate: Float
    ) throws -> UnsafeMutablePointer<Float> {

        let n = fftSize
        let halfN = n / 2
        let log2n = vDSP_Length(log2(Float(n)))

        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            throw NoiseReductionError.processingFailed
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))

        // Estimate noise from the first noiseEstimateSeconds of audio
        let noiseFrameLimit = max(1, Int(sampleRate * Float(noiseEstimateSeconds)) / hopSize)
        var noiseSpectrum = [Float](repeating: 0, count: halfN)
        var noiseFrameCount = 0

        var real = [Float](repeating: 0, count: halfN)
        var imag = [Float](repeating: 0, count: halfN)
        var frame = [Float](repeating: 0, count: n)
        var magnitude = [Float](repeating: 0, count: halfN)

        var pos = 0
        while pos + n <= count && noiseFrameCount < noiseFrameLimit {
            for i in 0..<n { frame[i] = samples[pos + i] }
            vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(n))

            forwardFFT(frame: &frame, real: &real, imag: &imag, setup: fftSetup, log2n: log2n, halfN: halfN)
            computeMagnitude(real: &real, imag: &imag, magnitude: &magnitude, halfN: halfN)

            vDSP_vadd(noiseSpectrum, 1, magnitude, 1, &noiseSpectrum, 1, vDSP_Length(halfN))
            noiseFrameCount += 1
            pos += hopSize
        }

        if noiseFrameCount > 0 {
            var div = Float(noiseFrameCount)
            vDSP_vsdiv(noiseSpectrum, 1, &div, &noiseSpectrum, 1, vDSP_Length(halfN))
        }

        var sf = subtractFactor
        vDSP_vsmul(noiseSpectrum, 1, &sf, &noiseSpectrum, 1, vDSP_Length(halfN))

        // Process all frames
        let output = UnsafeMutablePointer<Float>.allocate(capacity: count)
        output.initialize(repeating: 0, count: count)
        let norm = UnsafeMutablePointer<Float>.allocate(capacity: count)
        norm.initialize(repeating: 0, count: count)
        defer { norm.deallocate() }

        var phase = [Float](repeating: 0, count: halfN)
        var cleanMag = [Float](repeating: 0, count: halfN)
        var outputFrame = [Float](repeating: 0, count: n)

        pos = 0
        while pos + n <= count {
            for i in 0..<n { frame[i] = samples[pos + i] }
            vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(n))

            forwardFFT(frame: &frame, real: &real, imag: &imag, setup: fftSetup, log2n: log2n, halfN: halfN)
            computeMagnitude(real: &real, imag: &imag, magnitude: &magnitude, halfN: halfN)

            // Phase
            for i in 0..<halfN {
                phase[i] = atan2(imag[i], real[i])
            }

            // Subtract noise
            vDSP_vsub(noiseSpectrum, 1, magnitude, 1, &cleanMag, 1, vDSP_Length(halfN))

            // Floor
            var fl = spectralFloor
            vDSP_vthr(cleanMag, 1, &fl, &cleanMag, 1, vDSP_Length(halfN))

            // Reconstruct
            for i in 0..<halfN {
                real[i] = cleanMag[i] * cos(phase[i])
                imag[i] = cleanMag[i] * sin(phase[i])
            }

            inverseFFT(real: &real, imag: &imag, output: &outputFrame, setup: fftSetup, log2n: log2n, n: n, halfN: halfN)

            // Window again
            vDSP_vmul(outputFrame, 1, window, 1, &outputFrame, 1, vDSP_Length(n))

            // Overlap-add
            for i in 0..<n where pos + i < count {
                output[pos + i] += outputFrame[i]
                norm[pos + i] += window[i] * window[i]
            }

            pos += hopSize
        }

        // Normalize
        for i in 0..<count {
            if norm[i] > 1e-8 {
                output[i] /= norm[i]
            }
        }

        return output
    }

    // MARK: - FFT Helpers

    private func forwardFFT(
        frame: inout [Float],
        real: inout [Float],
        imag: inout [Float],
        setup: FFTSetup,
        log2n: vDSP_Length,
        halfN: Int
    ) {
        frame.withUnsafeBufferPointer { frameBuf in
            real.withUnsafeMutableBufferPointer { realBuf in
                imag.withUnsafeMutableBufferPointer { imagBuf in
                    var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                    frameBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { ptr in
                        vDSP_ctoz(ptr, 2, &split, 1, vDSP_Length(halfN))
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
        }
    }

    private func inverseFFT(
        real: inout [Float],
        imag: inout [Float],
        output: inout [Float],
        setup: FFTSetup,
        log2n: vDSP_Length,
        n: Int,
        halfN: Int
    ) {
        real.withUnsafeMutableBufferPointer { realBuf in
            imag.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))

                output.withUnsafeMutableBufferPointer { outBuf in
                    outBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { ptr in
                        vDSP_ztoc(&split, 1, ptr, 2, vDSP_Length(halfN))
                    }
                }
            }
        }
        var scale = 1.0 / Float(n * 2)
        vDSP_vsmul(output, 1, &scale, &output, 1, vDSP_Length(n))
    }

    private func computeMagnitude(
        real: inout [Float],
        imag: inout [Float],
        magnitude: inout [Float],
        halfN: Int
    ) {
        real.withUnsafeMutableBufferPointer { realBuf in
            imag.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                vDSP_zvabs(&split, 1, &magnitude, 1, vDSP_Length(halfN))
            }
        }
    }
}
