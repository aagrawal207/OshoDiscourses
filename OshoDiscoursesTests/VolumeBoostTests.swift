import AVFoundation
import Testing
@testable import OshoDiscourses

/// Tests for raising level above the system maximum.
///
/// The point of these is the pair of properties a boost has to have at once: it
/// must genuinely get louder, and it must not clip. A plain multiply gets the
/// first and fails the second on this archive, which is already mastered into
/// full scale.
struct VolumeBoostTests {

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let total = samples.reduce(into: Float(0)) { $0 += $1 * $1 }
        return (total / Float(samples.count)).squareRoot()
    }

    /// Speech-like, and specifically with speech's *dynamics*.
    ///
    /// The crest factor is the whole point. A boost cannot make a signal that
    /// already sits at full scale any louder — limiting it just clamps everything
    /// back to the ceiling, and an earlier version of this fixture (a continuous
    /// full-scale sine, ~3 dB of crest) measured the boost as 0.7 dB *quieter*.
    /// Real speech peaks occasionally and averages far below that: this archive
    /// runs about -13.8 dBFS RMS against 0 dBFS peaks. The gap is the headroom a
    /// boost is actually spending, so the fixture has to have one.
    private func speech(seconds: Double, sampleRate: Double) -> [Float] {
        let pitches: [Double] = [150, 232, 191, 305, 168, 264, 212]
        // Loud and quiet syllables, so peak and average are far apart.
        let amplitudes: [Double] = [0.99, 0.20, 0.50, 0.12, 0.60, 0.15, 0.35]
        var phase = 0.0
        var out = [Float](repeating: 0, count: Int(seconds * sampleRate))
        for index in out.indices {
            let t = Double(index) / sampleRate
            let slot = Int(t / 0.6)
            let within = t - Double(slot) * 0.6
            // Speaks for 0.25 s, then pauses for 0.35 s: the pauses pull the
            // average down further, as they do in speech.
            guard within < 0.25 else { out[index] = 0; phase = 0; continue }
            phase += 2 * Double.pi * pitches[slot % pitches.count] / sampleRate
            let envelope = min(within / 0.02, (0.25 - within) / 0.02, 1)
            let amplitude = amplitudes[slot % amplitudes.count]
            out[index] = Float(amplitude * max(envelope, 0) * sin(phase))
        }
        return out
    }

    private func run(
        signal: [Float],
        gain: Float,
        denoise: Bool,
        sampleRate: Double = 22_050
    ) throws -> [Float] {
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        )
        let processor = NoiseReductionProcessor()
        processor.prepare(channelCount: 1, maxFrames: 4096, sampleRate: sampleRate)
        processor.configure(
            mode: .rnnoise, wetMix: 0.5, intensity: 0.7,
            attenuationLimitDb: 12, voiceFocus: .focus,
            denoiseEnabled: denoise, outputGain: gain
        )

        var out = [Float]()
        var offset = 0
        while offset < signal.count {
            let count = min(4096, signal.count - offset)
            let block = try #require(
                AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))
            )
            block.frameLength = AVAudioFrameCount(count)
            let data = try #require(block.floatChannelData)
            for index in 0..<count { data[0][index] = signal[offset + index] }
            processor.process(buffer: block.mutableAudioBufferList, frameCount: block.frameLength)
            out.append(contentsOf: UnsafeBufferPointer(start: data[0], count: count))
            offset += count
        }
        return out
    }

    @Test func boostGetsLouderWithoutEverClipping() throws {
        // A plain multiply cannot do this. The source peaks at full scale, so 4x
        // would put 12 dB of it past the ceiling; limiting the peaks is what turns
        // the gain into loudness instead of distortion.
        let signal = speech(seconds: 4, sampleRate: 22_050)
        let reference = try run(signal: signal, gain: 1, denoise: true)
        let referenceLevel = rms(reference)

        print("boost ladder, crest factor of fixture: "
              + String(format: "%.1f dB", 20 * log10((signal.map(abs).max() ?? 1) / referenceLevel)))
        var lastLevel = referenceLevel
        for gain: Float in [1.5, 2.0, 3.0, 4.0] {
            let boosted = try run(signal: signal, gain: gain, denoise: true)
            let peak = boosted.map(abs).max() ?? 0
            #expect(peak <= 1.0, "boost of \(gain)x clipped at \(peak)")

            let level = rms(boosted)
            print(String(format: "  %.1fx -> %+.2f dB, peak %.3f", gain,
                         20 * log10(level / referenceLevel), peak))
            #expect(
                level > lastLevel,
                "boost of \(gain)x was not louder than the step below it"
            )
            lastLevel = level
        }

        // Worth having a floor on how much louder it actually gets: a limiter that
        // simply undid the gain would pass every check above.
        let loudest = try run(signal: signal, gain: 4, denoise: true)
        let gainDb = 20 * log10(rms(loudest) / referenceLevel)
        // The ceiling caps this: with peaks pinned at -1 dBFS the loudest a
        // signal can average is ceiling/sqrt(2) scaled by how much of the time it
        // is speaking, so on this fixture roughly 5 dB is all that is physically
        // available. 3 dB is a doubling of power and is the floor worth shipping a
        // control for.
        #expect(gainDb > 3, "4x boost only achieved \(gainDb) dB, which is not worth the control")
    }

    @Test func boostLeavesRawPlaybackUntouched() throws {
        // These full-scale recordings sound worse when gain spends their crest
        // factor through a limiter without first removing noise. Noise Reduction
        // off is therefore a hard passthrough boundary, even with stored gain.
        let signal = speech(seconds: 3, sampleRate: 22_050)
        let boosted = try run(signal: signal, gain: 3, denoise: false)
        #expect(boosted == signal)
    }

    @Test func deepFilterBypassDoesNotBoostRawPlayback() throws {
        // DeepFilterNet passes the source through while loading, unavailable, or
        // unsupported. Stored boost must not turn that bypass into limited audio.
        let sampleRate = 4_000.0
        let signal = speech(seconds: 1, sampleRate: sampleRate)
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)
        )
        let block = try #require(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(signal.count)
            )
        )
        block.frameLength = AVAudioFrameCount(signal.count)
        let data = try #require(block.floatChannelData)
        for index in signal.indices {
            data[0][index] = signal[index]
            data[1][index] = signal[index] * 0.5
        }
        let expectedLeft = signal
        let expectedRight = signal.map { $0 * 0.5 }

        let processor = NoiseReductionProcessor()
        processor.prepare(channelCount: 2, maxFrames: signal.count, sampleRate: sampleRate)
        processor.configure(
            mode: .deepFilterNet, wetMix: 0.5, intensity: 0.7,
            attenuationLimitDb: 12, voiceFocus: .focus,
            denoiseEnabled: true, outputGain: 3
        )
        processor.process(buffer: block.mutableAudioBufferList, frameCount: block.frameLength)

        #expect(Array(UnsafeBufferPointer(start: data[0], count: signal.count)) == expectedLeft)
        #expect(Array(UnsafeBufferPointer(start: data[1], count: signal.count)) == expectedRight)
    }

    @Test func unityBoostLeavesTheAudioExactlyAlone() throws {
        // No limiter, no gain, no rounding: at 1x the boost stage must be inert, or
        // it would colour playback for everyone who never touches the control.
        let signal = speech(seconds: 2, sampleRate: 22_050)
        let out = try run(signal: signal, gain: 1, denoise: false)
        #expect(out == signal, "the boost stage is not transparent at unity")
    }

    @MainActor
    @Test func theBoostCeilingIsReachableThroughTheService() {
        // The ladder in the player offers 4x; the service must not clamp it lower,
        // or the top step would silently do nothing.
        #expect(AudioPlayerService.maximumBoost >= 4.0)
    }
}
