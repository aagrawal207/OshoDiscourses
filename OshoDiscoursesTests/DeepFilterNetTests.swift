import AVFoundation
import Testing
@testable import OshoDiscourses

/// Tests for the native DeepFilterNet integration.
///
/// These exercise the real bundled model through the Rust/tract bridge rather
/// than a stub — the whole point of the feature is that inference actually runs
/// on device, so a mocked test would prove nothing about that.
struct DeepFilterNetTests {

    // MARK: - Bundled model

    @Test func modelIsBundledWithTheApp() throws {
        let url = try #require(
            DeepFilterProcessor.modelURL(),
            "DeepFilterNet3_onnx.tar.gz must ship in the app bundle"
        )
        let size = try FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        // The DFN3 ONNX export is ~7.6 MB; a few KB would mean a truncated or
        // placeholder file got committed.
        #expect(size > 1_000_000)
    }

    // MARK: - Bridge contract

    @Test func bridgeReportsDeepFilterNet3Geometry() throws {
        let url = try #require(DeepFilterProcessor.modelURL())
        let handle = try #require(dfb_create(url.path, 100), "model should load")
        defer { dfb_destroy(handle) }

        // The Swift FIFO logic depends on both of these exactly.
        #expect(dfb_hop_size(handle) == 480)
        #expect(dfb_sample_rate(handle) == 48_000)
    }

    @Test func bridgeRejectsWrongFrameLength() throws {
        let url = try #require(DeepFilterProcessor.modelURL())
        let handle = try #require(dfb_create(url.path, 100))
        defer { dfb_destroy(handle) }

        var input = [Float](repeating: 0, count: 128)
        var output = [Float](repeating: 0, count: 128)
        // A short frame must be refused, not read out of bounds.
        let status = dfb_process_frame(handle, &input, &output, 128, nil)
        #expect(status == DFB_ERR_ARG)
    }

    @Test func bridgeSurvivesNullAndBadInput() {
        // The whole reason for the custom bridge: none of this may crash.
        #expect(dfb_hop_size(nil) == 0)
        #expect(dfb_sample_rate(nil) == 0)
        #expect(dfb_set_atten_lim(nil, 20) == DFB_ERR_NULL)
        #expect(dfb_set_post_filter_beta(nil, 0.02) == DFB_ERR_NULL)
        #expect(dfb_reset(nil) == DFB_ERR_NULL)
        #expect(dfb_process_frame(nil, nil, nil, 480, nil) == DFB_ERR_NULL)
        dfb_destroy(nil)
        // A path that is not a model must fail cleanly rather than panic.
        #expect(dfb_create("/nonexistent/model.tar.gz", 100) == nil)
    }

    @Test func bridgeAcceptsAttenuationAndResetChanges() throws {
        let url = try #require(DeepFilterProcessor.modelURL())
        let handle = try #require(dfb_create(url.path, 100))
        defer { dfb_destroy(handle) }

        #expect(dfb_set_atten_lim(handle, 12) == DFB_OK)
        #expect(dfb_set_post_filter_beta(handle, 0.02) == DFB_OK)
        #expect(dfb_reset(handle) == DFB_OK)
        // Negative/NaN must be rejected, not forwarded into the model.
        #expect(dfb_set_atten_lim(handle, -1) == DFB_ERR_ARG)
        #expect(dfb_set_atten_lim(handle, .nan) == DFB_ERR_ARG)
    }

    /// The core behavioural claim: the model suppresses broadband noise.
    @Test func modelAttenuatesBroadbandNoise() throws {
        let url = try #require(DeepFilterProcessor.modelURL())
        let handle = try #require(dfb_create(url.path, 100))
        defer { dfb_destroy(handle) }

        let hop = dfb_hop_size(handle)
        var generator = SplitMix64(seed: 0x0570_1234)
        var outputEnergy: Float = 0
        var inputEnergy: Float = 0
        var frameOut = [Float](repeating: 0, count: hop)

        // ~1s of white noise. The first frames cover the model's warm-up, so
        // only the tail is measured.
        let frameCount = 100
        for frame in 0..<frameCount {
            var frameIn = (0..<hop).map { _ in generator.nextUniform() * 0.3 }
            let status = dfb_process_frame(handle, &frameIn, &frameOut, hop, nil)
            #expect(status == DFB_OK)
            guard frame > frameCount / 2 else { continue }
            inputEnergy += frameIn.reduce(0) { $0 + $1 * $1 }
            outputEnergy += frameOut.reduce(0) { $0 + $1 * $1 }
        }

        // Speech-free noise should be pushed far down.
        #expect(outputEnergy < inputEnergy * 0.5)
    }

    // MARK: - DeepFilterProcessor

    @Test func processorRefusesOnlyImplausibleSampleRates() async {
        let processor = DeepFilterProcessor()
        // 1 kHz is not a real audio rate; resampling from it is meaningless.
        processor.activate(channelCount: 1, maxFrames: 1024, sampleRate: 1_000)

        #expect(processor.currentStatus == .unsupportedSampleRate(1_000))
        #expect(processor.currentStatus.isBypassing)

        var samples: [Float] = [0.25, -0.5, 0.75, -1.0]
        let original = samples
        let processed = samples.withUnsafeMutableBufferPointer { buffer in
            processor.process(samples: buffer.baseAddress!, count: buffer.count, channelIndex: 0)
        }
        #expect(processed == false)
        #expect(samples == original)
    }

    /// The catalog is 22,050 Hz, so this is the path that actually matters:
    /// without resampling the 48 kHz model could never run on these recordings.
    @Test func processorRunsOn22kHzCatalogAudioByResampling() async throws {
        let processor = DeepFilterProcessor()
        processor.activate(channelCount: 1, maxFrames: 4096, sampleRate: 22_050)
        try await waitForActive(processor)

        var generator = SplitMix64(seed: 4242)
        var inputEnergy: Float = 0
        var outputEnergy: Float = 0
        for index in 0..<80 {
            var buffer = (0..<1024).map { _ in generator.nextUniform() * 0.3 }
            let before = buffer.reduce(0) { $0 + $1 * $1 }
            let handled = buffer.withUnsafeMutableBufferPointer { pointer in
                processor.process(samples: pointer.baseAddress!, count: pointer.count, channelIndex: 0)
            }
            #expect(handled, "22.05 kHz audio must be processed, not bypassed")
            #expect(buffer.count == 1024)
            #expect(buffer.allSatisfy { $0.isFinite })
            guard index > 30 else { continue }   // skip warm-up + priming latency
            inputEnergy += before
            outputEnergy += buffer.reduce(0) { $0 + $1 * $1 }
        }
        // Speech-free noise at the catalog's real sample rate must come down.
        #expect(outputEnergy < inputEnergy * 0.6)
    }

    @Test func processorBecomesActiveAndDenoises() async throws {
        let processor = DeepFilterProcessor()
        processor.activate(channelCount: 1, maxFrames: 4096, sampleRate: 48_000)

        try await waitForActive(processor)

        // Feed noise through the public (FIFO-based) path in tap-sized buffers.
        var generator = SplitMix64(seed: 99)
        let bufferSize = 1024
        var inputEnergy: Float = 0
        var outputEnergy: Float = 0

        for index in 0..<60 {
            var buffer = (0..<bufferSize).map { _ in generator.nextUniform() * 0.3 }
            let before = buffer.reduce(0) { $0 + $1 * $1 }
            let handled = buffer.withUnsafeMutableBufferPointer { pointer in
                processor.process(samples: pointer.baseAddress!, count: pointer.count, channelIndex: 0)
            }
            #expect(handled)
            // Skip warm-up plus the primed one-hop latency.
            guard index > 20 else { continue }
            inputEnergy += before
            outputEnergy += buffer.reduce(0) { $0 + $1 * $1 }
        }

        #expect(outputEnergy < inputEnergy * 0.5)
    }

    @Test func processorPreservesBufferLengthAndStaysFinite() async throws {
        let processor = DeepFilterProcessor()
        processor.activate(channelCount: 1, maxFrames: 2048, sampleRate: 48_000)
        try await waitForActive(processor)

        // Deliberately ragged sizes: taps do not hand over neat multiples of 480.
        for count in [480, 1024, 37, 999, 2048, 1] {
            var buffer = [Float](repeating: 0.1, count: count)
            let handled = buffer.withUnsafeMutableBufferPointer { pointer in
                processor.process(samples: pointer.baseAddress!, count: pointer.count, channelIndex: 0)
            }
            #expect(handled)
            #expect(buffer.count == count)
            #expect(buffer.allSatisfy { $0.isFinite })
        }
    }

    @Test func processorIgnoresChannelsItHasNoModelFor() async throws {
        let processor = DeepFilterProcessor()
        processor.activate(channelCount: 1, maxFrames: 1024, sampleRate: 48_000)
        try await waitForActive(processor)

        var samples = [Float](repeating: 0.4, count: 480)
        let original = samples
        // Only channel 0 was loaded; channel 1 must pass through untouched.
        let handled = samples.withUnsafeMutableBufferPointer { pointer in
            processor.process(samples: pointer.baseAddress!, count: pointer.count, channelIndex: 1)
        }
        #expect(handled == false)
        #expect(samples == original)
    }

    @Test func processorLoadsOneModelPerChannelForStereo() async throws {
        let processor = DeepFilterProcessor()
        processor.activate(channelCount: 2, maxFrames: 1024, sampleRate: 48_000)
        try await waitForActive(processor)

        // Both channels must denoise independently; DeepFilterNet is mono, so a
        // second channel needs its own model instance and its own FIFO.
        for channel in 0..<2 {
            var buffer = [Float](repeating: 0.25, count: 960)
            let handled = buffer.withUnsafeMutableBufferPointer { pointer in
                processor.process(samples: pointer.baseAddress!, count: pointer.count, channelIndex: channel)
            }
            #expect(handled, "channel \(channel) should be processed")
            #expect(buffer.allSatisfy { $0.isFinite })
        }
    }

    @Test func growingFromMonoToStereoAddsOnlyTheMissingChannel() async throws {
        let processor = DeepFilterProcessor()
        processor.activate(channelCount: 1, maxFrames: 1024, sampleRate: 48_000)
        try await waitForActive(processor)

        // A stereo track after a mono one. This must top up to exactly 2 voices,
        // not stack a second full set on top of the first.
        processor.activate(channelCount: 2, maxFrames: 1024, sampleRate: 48_000)
        try await waitForActive(processor)

        for channel in 0..<2 {
            var buffer = [Float](repeating: 0.2, count: 480)
            let handled = buffer.withUnsafeMutableBufferPointer { pointer in
                processor.process(samples: pointer.baseAddress!, count: pointer.count, channelIndex: channel)
            }
            #expect(handled, "channel \(channel) should be processed")
        }
        // A third channel was never requested, so it must stay passthrough.
        var extra = [Float](repeating: 0.2, count: 480)
        let original = extra
        let handled = extra.withUnsafeMutableBufferPointer { pointer in
            processor.process(samples: pointer.baseAddress!, count: pointer.count, channelIndex: 2)
        }
        #expect(handled == false)
        #expect(extra == original)
    }

    @Test func resetAndAttenuationChangesDoNotBreakProcessing() async throws {
        let processor = DeepFilterProcessor()
        processor.activate(channelCount: 1, maxFrames: 1024, sampleRate: 48_000)
        try await waitForActive(processor)

        processor.reset()
        processor.setAttenuationLimit(6)
        #expect(processor.currentStatus == .active)

        var buffer = [Float](repeating: 0.2, count: 960)
        let handled = buffer.withUnsafeMutableBufferPointer { pointer in
            processor.process(samples: pointer.baseAddress!, count: pointer.count, channelIndex: 0)
        }
        #expect(handled)
        #expect(buffer.allSatisfy { $0.isFinite })
    }

    @Test func invalidateReturnsToIdleAndStopsProcessing() async throws {
        let processor = DeepFilterProcessor()
        processor.activate(channelCount: 1, maxFrames: 1024, sampleRate: 48_000)
        try await waitForActive(processor)

        processor.invalidate()
        #expect(processor.currentStatus == .idle)

        var samples = [Float](repeating: 0.3, count: 480)
        let original = samples
        let handled = samples.withUnsafeMutableBufferPointer { pointer in
            processor.process(samples: pointer.baseAddress!, count: pointer.count, channelIndex: 0)
        }
        #expect(handled == false)
        #expect(samples == original)
    }

    // MARK: - Status semantics

    @Test func onlyActiveAndIdleCountAsNotBypassing() {
        #expect(DeepFilterProcessor.Status.active.isBypassing == false)
        #expect(DeepFilterProcessor.Status.idle.isBypassing == false)
        #expect(DeepFilterProcessor.Status.loading.isBypassing)
        #expect(DeepFilterProcessor.Status.modelMissing.isBypassing)
        #expect(DeepFilterProcessor.Status.initializationFailed.isBypassing)
        #expect(DeepFilterProcessor.Status.runtimeFailure.isBypassing)
        #expect(DeepFilterProcessor.Status.unsupportedSampleRate(44_100).isBypassing)
        // Every state must be describable to the listener.
        #expect(DeepFilterProcessor.Status.active.label == "Active")
        #expect(DeepFilterProcessor.Status.loading.label.isEmpty == false)
    }

    // MARK: - Wiring

    @Test func deepFilterNetIsSelectableAndPersists() {
        #expect(NoiseReductionMode.allCases.contains(.deepFilterNet))
        // Raw value is the persisted key: changing it would silently reset the
        // listener's stored choice.
        #expect(NoiseReductionMode.deepFilterNet.rawValue == "deepFilterNet")
        #expect(NoiseReductionMode(rawValue: "deepFilterNet") == .deepFilterNet)
        #expect(NoiseReductionMode.deepFilterNet.displayName == "DeepFilterNet")
        #expect(NoiseReductionMode.deepFilterNet.detail.isEmpty == false)
        #expect(NoiseReductionMode.deepFilterNet.shortDescriptor.isEmpty == false)
    }

    @Test func strengthMapsToAttenuationLimitNotWetMix() {
        // Strength must reach DeepFilterNet as the model's own dB cap, ordered
        // weakest-to-strongest, with Strong meaning "unlimited" (>= 100 dB).
        let light = AudioPlayerService.DenoiseStrength.light.attenuationLimitDb
        let medium = AudioPlayerService.DenoiseStrength.medium.attenuationLimitDb
        let strong = AudioPlayerService.DenoiseStrength.strong.attenuationLimitDb
        #expect(light < medium)
        #expect(medium < strong)
        #expect(light > 0)
        #expect(strong >= 100)
    }

    @Test func noiseProcessorRoutesDeepFilterNetWithoutEmittingSilence() {
        // Selecting DeepFilterNet must not break the shared tap host. With no
        // model loaded yet it must leave audio alone rather than emit silence.
        let processor = NoiseReductionProcessor()
        processor.configure(
            mode: .deepFilterNet, wetMix: 1, intensity: 1,
            attenuationLimitDb: 12, voiceFocus: .focus
        )
        processor.prepare(channelCount: 1, maxFrames: 480, sampleRate: 22_050)

        var samples = [Float](repeating: 0.5, count: 480)
        let original = samples
        processSamples(&samples, with: processor)
        #expect(samples == original, "unloaded model must be transparent passthrough")
    }

    @Test func voiceFocusPresetsArePersistableAndDistinct() {
        #expect(VoiceFocusPreset.allCases.count == 3)
        for preset in VoiceFocusPreset.allCases {
            #expect(VoiceFocusPreset(rawValue: preset.rawValue) == preset)
            #expect(preset.displayName.isEmpty == false)
            #expect(preset.detail.isEmpty == false)
        }
        // Strong must duck harder than Focus, and only the lifting presets lift.
        let focus = VoiceFocusChain.Parameters.forPreset(.focus)
        let lift = VoiceFocusChain.Parameters.forPreset(.lift)
        let strong = VoiceFocusChain.Parameters.forPreset(.strong)
        #expect(focus.liftMaxDb == 0)
        #expect(lift.liftMaxDb > 0)
        #expect(strong.liftMaxDb > 0)
        #expect(strong.duckFloorDb < focus.duckFloorDb)
    }

    /// The behavioural claim behind Voice Focus: noise-only stretches are pushed
    /// down harder than speech, so the voice sits forward even when the two
    /// overlap in frequency.
    @Test func voiceFocusRaisesSpeechToPauseContrast() {
        let sampleRate = 48_000.0
        let hop = 480
        let frames = 600

        func buildSignal() -> [[Float]] {
            var generator = SplitMix64(seed: 7)
            return (0..<frames).map { frame in
                // Alternate ~0.5 s of "speech" and pause, both sitting on noise.
                let speaking = (frame / 150) % 2 == 0
                return (0..<hop).map { index -> Float in
                    let t = Double(frame * hop + index) / sampleRate
                    let noise = generator.nextUniform() * 0.05
                    guard speaking else { return noise }
                    // Harmonic stack in the band this archive actually uses.
                    let voice = 0.25 * sin(2 * .pi * 220 * t)
                        + 0.12 * sin(2 * .pi * 440 * t)
                        + 0.06 * sin(2 * .pi * 660 * t)
                    return Float(voice) + noise
                }
            }
        }

        func rms(_ v: [Float]) -> Float { sqrt(v.reduce(0) { $0 + $1 * $1 } / Float(v.count)) }

        let source = buildSignal()
        let chain = VoiceFocusChain(sampleRate: sampleRate, parameters: .focus)
        var processed: [[Float]] = []
        for (index, frame) in source.enumerated() {
            var scratch = frame
            // Stand in for the model's local SNR: high while speaking.
            let snr: Float = (index / 150) % 2 == 0 ? 14 : -8
            scratch.withUnsafeMutableBufferPointer { pointer in
                chain.process(frame: pointer.baseAddress!, count: pointer.count, localSnrDb: snr)
            }
            processed.append(scratch)
        }

        // Compare middle frames of each kind to avoid smoothing transitions.
        func average(_ frames: [[Float]], speaking: Bool) -> Float {
            // Only steady-state frames: at least 1 s into each block, so the
            // deliberately slow gate envelope has settled.
            let picked = frames.enumerated().filter { index, _ in
                ((index / 150) % 2 == 0) == speaking && index % 150 > 100
            }
            return picked.reduce(Float(0)) { $0 + rms($1.element) } / Float(picked.count)
        }

        let beforeRatio = 20 * log10(average(source, speaking: true) / average(source, speaking: false))
        let afterRatio = 20 * log10(average(processed, speaking: true) / average(processed, speaking: false))
        #expect(afterRatio > beforeRatio + 6, "expected a clear contrast gain, got \(afterRatio - beforeRatio) dB")
        #expect(processed.allSatisfy { $0.allSatisfy(\.isFinite) })
    }

    /// Regression test for the reported bug: the ends of Osho's sentences were
    /// being muted. His voice decays as a sentence finishes, so the model's local
    /// SNR collapses on the final words, and the first gate closed on them with a
    /// 10 ms time constant. The gate must be slow to close and must hold open
    /// after speech, so a trailing word survives while real pauses still duck.
    @Test func gateDoesNotSwallowTheEndsOfSentences() {
        let sampleRate = 48_000.0
        let hop = 480

        // 300 ms of steady speech, then a 250 ms decay (falling level *and*
        // falling SNR, as measured at 41:37), then a long pause.
        let speechFrames = 30
        let tailFrames = 25
        let pauseFrames = 250

        struct Frame { var samples: [Float]; var snr: Float }
        var frames: [Frame] = []
        var generator = SplitMix64(seed: 31)
        var phase = 0.0

        func tone(_ amplitude: Double) -> [Float] {
            (0..<hop).map { _ in
                phase += 2 * .pi * 220 / sampleRate
                let harmonics = sin(phase) + 0.4 * sin(2 * phase) + 0.2 * sin(3 * phase)
                return Float(amplitude * harmonics) + generator.nextUniform() * 0.004
            }
        }

        for _ in 0..<speechFrames { frames.append(Frame(samples: tone(0.25), snr: 16)) }
        for index in 0..<tailFrames {
            // Level and SNR both fall away, exactly the case that broke.
            let fraction = Double(index) / Double(tailFrames)
            let amplitude = 0.25 * (1 - fraction) + 0.01
            let snr = Float(16 - 30 * fraction)   // +16 dB down to -14 dB
            frames.append(Frame(samples: tone(amplitude), snr: snr))
        }
        for _ in 0..<pauseFrames {
            frames.append(Frame(
                samples: (0..<hop).map { _ in generator.nextUniform() * 0.01 },
                snr: -14
            ))
        }

        let chain = VoiceFocusChain(sampleRate: sampleRate, parameters: .focus)
        var gains: [Float] = []
        for frame in frames {
            var scratch = frame.samples
            let before = rms(scratch)
            scratch.withUnsafeMutableBufferPointer { pointer in
                chain.process(frame: pointer.baseAddress!, count: pointer.count, localSnrDb: frame.snr)
            }
            let after = rms(scratch)
            gains.append(20 * log10(max(after, 1e-9) / max(before, 1e-9)))
        }

        // Mid-sentence reference, skipping the chain's own settling.
        let midGain = average(gains[10..<speechFrames])
        // The first 150 ms of the decay is where the words actually are.
        let tailGain = average(gains[speechFrames..<(speechFrames + 15)])
        // Deep into a long pause, well past hold and the slow close, so this
        // measures steady-state ducking rather than the decay ramp.
        let pauseGain = average(gains[(gains.count - 60)...])

        #expect(
            tailGain > midGain - 6,
            "sentence tail attenuated \(midGain - tailGain) dB below mid-speech — the gate is eating word endings"
        )
        #expect(
            pauseGain < midGain - 8,
            "steady noise in a long pause is not being ducked (pause \(pauseGain) dB vs speech \(midGain) dB)"
        )
        // And the hold must not be so long that it never ducks at all.
        #expect(pauseGain < -6)
    }

    @Test func liftTracksSpeechLevelRatherThanEachFrame() {
        // Per-frame levelling boosted quiet noise in the gaps harder than the
        // voice (measured +7.9 dB against speech's +3.7 dB). A quiet noise-only
        // frame at low SNR must not be amplified.
        let sampleRate = 48_000.0
        let hop = 480
        let chain = VoiceFocusChain(sampleRate: sampleRate, parameters: .lift)

        var generator = SplitMix64(seed: 5)
        // Long stretch of noise-only frames at clearly negative SNR.
        var lastGain: Float = 0
        for _ in 0..<120 {
            var frame = (0..<hop).map { _ in generator.nextUniform() * 0.004 }
            let before = rms(frame)
            frame.withUnsafeMutableBufferPointer { pointer in
                chain.process(frame: pointer.baseAddress!, count: pointer.count, localSnrDb: -12)
            }
            lastGain = 20 * log10(max(rms(frame), 1e-9) / max(before, 1e-9))
        }
        #expect(lastGain < 0, "noise-only frames must never be boosted, got \(lastGain) dB")
    }

    @Test func presetsRemainOrderedByAggressiveness() {
        let focus = VoiceFocusChain.Parameters.forPreset(.focus)
        let lift = VoiceFocusChain.Parameters.forPreset(.lift)
        let strong = VoiceFocusChain.Parameters.forPreset(.strong)
        // Every preset must hold long enough to protect a trailing word.
        for parameters in [focus, lift, strong] {
            #expect(parameters.holdMs >= 120, "hold too short to protect sentence endings")
            #expect(parameters.closeMs >= 200, "gate closes too fast; this is what cut word endings")
        }
        // Strong should reach a deeper floor, and sooner, than Focus.
        #expect(strong.duckFloorDb < focus.duckFloorDb)
        #expect(strong.closeMs <= focus.closeMs)
    }

    // MARK: - Helpers

    private func rms(_ v: [Float]) -> Float {
        sqrt(v.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(v.count, 1)))
    }

    private func average(_ v: ArraySlice<Float>) -> Float {
        v.reduce(Float(0), +) / Float(max(v.count, 1))
    }

    private func waitForActive(
        _ processor: DeepFilterProcessor,
        timeout: Duration = .seconds(20)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let status = processor.currentStatus
            if status == .active { return }
            if status != .loading, status != .idle {
                Issue.record("DeepFilterNet failed to load: \(status.label)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("DeepFilterNet did not become active within \(timeout)")
        throw CancellationError()
    }

    private func processSamples(_ samples: inout [Float], with processor: NoiseReductionProcessor) {
        let frameCount = UInt32(samples.count)
        samples.withUnsafeMutableBytes { bytes in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(bytes.count),
                    mData: bytes.baseAddress
                )
            )
            withUnsafeMutablePointer(to: &list) {
                processor.process(buffer: $0, frameCount: frameCount)
            }
        }
    }
}

/// Deterministic PRNG so noise-suppression assertions are reproducible rather
/// than occasionally flaky.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [-1, 1).
    mutating func nextUniform() -> Float {
        Float(Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)) * 2 - 1
    }
}
