import AVFoundation
import Synchronization
import Testing
@testable import OshoDiscourses

struct NoiseTapGenerationTests {
    @Test func audioMixStorageRetainsTheRequestedContext() throws {
        let processor = configured()
        let composition = AVMutableComposition()
        let track = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        let mix = try #require(processor.createAudioMix(for: track, generation: 7))
        let parameters = try #require(mix.inputParameters.first)
        let tap = try #require(parameters.audioTapProcessor)
        let context = Unmanaged<NoiseReductionTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
        #expect(context.generation == 7)
        #expect(processor.diagnosticsSnapshot().tapGeneration == 7)
        processor.retireAudioMix(generation: 7)
        #expect(context.isRetired)
        #expect(processor.diagnosticsSnapshot().tapGeneration == nil)
    }

    @Test func replacingATapStartsItsOwnCountersAndIgnoresOldCallbacks() async throws {
        let processor = configured()
        let old = try #require(processor.makeTapContext(generation: 10))
        old.prepare(channelCount: 1, maxFrames: 1024, sampleRate: 22_050)
        try await waitPrepared(old)
        _ = send(old, value: 0.25)
        #expect(processor.diagnosticsSnapshot().processedBuffers == 1)

        let current = try #require(processor.makeTapContext(generation: 11))
        var snapshot = processor.diagnosticsSnapshot()
        #expect(snapshot.tapGeneration == 11)
        #expect(!snapshot.isPrepared)
        #expect(snapshot.processedBuffers == 0)
        current.prepare(channelCount: 1, maxFrames: 1024, sampleRate: 22_050)
        try await waitPrepared(current)
        _ = send(current, value: 0.3)
        let before = processor.diagnosticsSnapshot()

        old.prepare(channelCount: 8, maxFrames: 12, sampleRate: 8_000)
        old.unprepare()
        old.requestDiscontinuity()
        processor.requestDiscontinuity(generation: 10)
        processor.retireAudioMix(generation: 10)
        let raw = send(old, value: 0.75, flags: kMTAudioProcessingTapFlag_StartOfStream)
        #expect(raw.samples.allSatisfy { $0 == 0.75 })
        let failed = send(old, value: 0.6, status: -50)
        #expect(failed.frames == 0)
        #expect(failed.flags == 0)
        snapshot = processor.diagnosticsSnapshot()
        #expect(snapshot.tapGeneration == 11)
        #expect(snapshot.isPrepared)
        #expect(snapshot.processedBuffers == before.processedBuffers)
        #expect(snapshot.sourceReadFailures == before.sourceReadFailures)
        #expect(snapshot.sourceDiscontinuities == before.sourceDiscontinuities)
        #expect(snapshot.resetRequests == before.resetRequests)
        #expect(snapshot.streamResets == before.streamResets)
        #expect(!snapshot.sourceReadFailed && !snapshot.resetPending)
    }

    @Test func oldPreparationCompletingAfterReplacementCannotPublishOrResetTheNewTap() async throws {
        let entered = Atomic<Bool>(false)
        let release = DispatchSemaphore(value: 0)
        let calls = Atomic<Int>(0)
        let processor = NoiseReductionProcessor(rnnoiseFactory: { rate, frames, _ in
            if calls.wrappingAdd(1, ordering: .relaxed).oldValue == 0 {
                entered.store(true, ordering: .releasing)
                release.wait()
            }
            return RNNoiseProcessor(sourceRate: rate, maxFrames: frames)
        })
        let old = try #require(processor.makeTapContext(generation: 1))
        defer { release.signal() }
        old.prepare(channelCount: 1, maxFrames: 1024, sampleRate: 22_050)
        let deadline = ContinuousClock.now + .seconds(5)
        while !entered.load(ordering: .acquiring), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let preparationEntered = entered.load(ordering: .acquiring)
        try #require(preparationEntered)
        let current = try #require(processor.makeTapContext(generation: 2))
        current.prepare(channelCount: 1, maxFrames: 1024, sampleRate: 22_050)
        try await waitPrepared(current)
        _ = send(current, value: 0.2)
        let before = processor.diagnosticsSnapshot()
        #expect(send(old, value: 0.4).samples.allSatisfy { $0 == 0.4 })
        _ = send(old, value: 0.4, status: -50)
        old.unprepare()
        release.signal()
        try await waitRetired(old)
        let after = processor.diagnosticsSnapshot()
        #expect(after.tapGeneration == 2 && after.isPrepared)
        #expect(after.processedBuffers == before.processedBuffers)
        #expect(after.streamResets == before.streamResets)
        #expect(after.resetRequests == before.resetRequests)
        #expect(after.sourceReadFailures == 0)
        #expect(!after.sourceReadFailed)
    }

    @Test func retiredModelLoadCannotBecomeTheCurrentModel() async throws {
        let processor = configured(mode: .deepFilterNet)
        let old = try #require(processor.makeTapContext(generation: 20))
        old.prepare(channelCount: 1, maxFrames: 1024, sampleRate: 22_050)
        try await waitPrepared(old)
        let current = try #require(processor.makeTapContext(generation: 21))
        current.prepare(channelCount: 1, maxFrames: 1024, sampleRate: 22_050)
        try await waitPrepared(current, model: true)
        try await waitRetired(old)
        old.stream.deepFilter.activate(channelCount: 1, maxFrames: 1024, sampleRate: 48_000)
        _ = send(old, value: 0.8, status: -50)
        _ = send(current, value: 0.3)
        let snapshot = processor.diagnosticsSnapshot()
        #expect(snapshot.tapGeneration == 21 && snapshot.isPrepared)
        #expect(snapshot.deepFilterStatus == .active)
        #expect(snapshot.processedBuffers == 1)
        #expect(snapshot.sourceReadFailures == 0)
        #expect(old.stream.deepFilter.currentStatus == .idle)
    }

    @Test func unprepareWinsOverAnInFlightPreparationInTheSameGeneration() async throws {
        let entered = Atomic<Bool>(false)
        let release = DispatchSemaphore(value: 0)
        let processor = NoiseReductionProcessor(rnnoiseFactory: { rate, frames, _ in
            entered.store(true, ordering: .releasing)
            release.wait()
            return RNNoiseProcessor(sourceRate: rate, maxFrames: frames)
        })
        let context = try #require(processor.makeTapContext(generation: 25))
        defer { release.signal() }
        context.prepare(channelCount: 1, maxFrames: 1024, sampleRate: 22_050)
        let deadline = ContinuousClock.now + .seconds(5)
        while !entered.load(ordering: .acquiring), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let preparationEntered = entered.load(ordering: .acquiring)
        try #require(preparationEntered)
        context.unprepare()
        #expect(send(context, value: 0.6).samples.allSatisfy { $0 == 0.6 })
        release.signal()
        while context.stream.diagnosticsSnapshot().isPrepared, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let snapshot = processor.diagnosticsSnapshot()
        #expect(snapshot.tapGeneration == 25)
        #expect(!snapshot.isPrepared)
        #expect(snapshot.processedBuffers == 0)
        #expect(send(context, value: 0.7).samples.allSatisfy { $0 == 0.7 })
    }

    @Test func queuedPreparationDeliveryDoesNotReapplyTheLatestRevision() async throws {
        let factoryCalls = Atomic<Int>(0)
        let deliveries = Atomic<Int>(0)
        let entered = Atomic<Bool>(false)
        let lastFrames = Atomic<Int>(0)
        let release = DispatchSemaphore(value: 0)
        let context = NoiseReductionTapContext(generation: 26, rnnoiseFactory: { rate, frames, _ in
            lastFrames.store(frames, ordering: .relaxed)
            if factoryCalls.wrappingAdd(1, ordering: .relaxed).oldValue == 0 {
                entered.store(true, ordering: .releasing)
                release.wait()
            }
            return RNNoiseProcessor(sourceRate: rate, maxFrames: frames)
        }, preparationDeliveryDidFinish: {
            _ = deliveries.wrappingAdd(1, ordering: .releasing)
        })
        defer { release.signal(); context.retire() }
        context.prepare(channelCount: 1, maxFrames: 1024, sampleRate: 22_050)
        let deadline = ContinuousClock.now + .seconds(10)
        while !entered.load(ordering: .acquiring), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let preparationEntered = entered.load(ordering: .acquiring)
        try #require(preparationEntered)
        context.unprepare()
        context.prepare(channelCount: 1, maxFrames: 2048, sampleRate: 48_000)
        release.signal()

        // The second completion drains the add events queued inside the first
        // handler; readiness alone can become true before that delivery runs.
        while deliveries.load(ordering: .acquiring) < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let completedDeliveries = deliveries.load(ordering: .acquiring)
        let calls = factoryCalls.load(ordering: .relaxed)
        let frames = lastFrames.load(ordering: .relaxed)
        try #require(completedDeliveries >= 2)
        #expect(calls == 2, "the latest format must be applied once, not again by the queued delivery")
        #expect(frames == 2048)
        let snapshot = context.diagnosticsSnapshot()
        #expect(snapshot.tapGeneration == 26 && snapshot.isPrepared)
        #expect(snapshot.processedBuffers == 0 && snapshot.streamResets == 0)
    }

    @Test func retirementFencesCanceledGenerationsAndDoesNotRelabelStandaloneData() async throws {
        let processor = configured()
        processor.prepare(channelCount: 1, maxFrames: 16, sampleRate: 22_050)
        var data = [Float](repeating: 0.2, count: 16)
        data.withUnsafeMutableBytes { bytes in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 1, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress
            ))
            processor.process(buffer: &list, frameCount: 16)
        }
        #expect(processor.diagnosticsSnapshot().tapGeneration == nil)
        #expect(processor.diagnosticsSnapshot().processedBuffers == 1)
        let context = try #require(processor.makeTapContext(generation: 30))
        #expect(processor.diagnosticsSnapshot().processedBuffers == 0)
        context.prepare(channelCount: 1, maxFrames: 1024, sampleRate: 22_050)
        try await waitPrepared(context)
        processor.retireAudioMix(generation: 30)
        context.prepare(channelCount: 1, maxFrames: 1024, sampleRate: 48_000)
        _ = send(context, value: 0.5)
        let snapshot = processor.diagnosticsSnapshot()
        #expect(snapshot.tapGeneration == nil && !snapshot.isPrepared)
        #expect(snapshot.processedBuffers == 0)
        #expect(snapshot.deepFilterStatus == .idle)
        #expect(processor.makeTapContext(generation: 30) == nil)
        processor.retireAudioMix(generation: 31)
        #expect(processor.makeTapContext(generation: 31) == nil)
        #expect(processor.makeTapContext(generation: 32) != nil)
    }

    @Test func sourceDiscontinuityKeepsItsGenerationAndUnprepareClearsReadiness() async throws {
        let processor = configured()
        let context = try #require(processor.makeTapContext(generation: 40))
        context.prepare(channelCount: 1, maxFrames: 1024, sampleRate: 22_050)
        try await waitPrepared(context)
        _ = send(context, value: 0.7)
        _ = send(context, value: 0, flags: kMTAudioProcessingTapFlag_StartOfStream, frames: 0)
        let deadline = ContinuousClock.now + .seconds(5)
        while processor.diagnosticsSnapshot().resetPending, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        var snapshot = processor.diagnosticsSnapshot()
        #expect(snapshot.tapGeneration == 40 && snapshot.isPrepared)
        #expect(snapshot.sourceDiscontinuities == 1)
        #expect(snapshot.streamResets == 1)
        #expect(!snapshot.resetPending)
        context.unprepare()
        snapshot = processor.diagnosticsSnapshot()
        #expect(snapshot.tapGeneration == 40 && !snapshot.isPrepared)
        #expect(send(context, value: 0.25).samples.allSatisfy { $0 == 0.25 })
    }

    private func configured(mode: NoiseReductionMode = .cadence) -> NoiseReductionProcessor {
        let processor = NoiseReductionProcessor()
        processor.configure(mode: mode, wetMix: 0.5, intensity: 0.7, attenuationLimitDb: 12, voiceFocus: .focus)
        return processor
    }

    private func waitPrepared(_ context: NoiseReductionTapContext, model: Bool = false) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            let snapshot = context.diagnosticsSnapshot()
            if snapshot.isPrepared && (!model || snapshot.deepFilterStatus.isActive) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("tap preparation did not complete")
        throw CancellationError()
    }

    private func waitRetired(_ context: NoiseReductionTapContext) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            let snapshot = context.stream.diagnosticsSnapshot()
            if !snapshot.isPrepared && snapshot.deepFilterStatus == .idle { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("retired stream did not finish cleanup")
        throw CancellationError()
    }

    private func send(
        _ context: NoiseReductionTapContext, value: Float,
        flags: MTAudioProcessingTapFlags = 0, status: OSStatus = noErr, frames: Int = 1024
    ) -> (samples: [Float], frames: Int, flags: MTAudioProcessingTapFlags) {
        var samples = [Float](repeating: value, count: 1024)
        var returned = frames
        var outputFlags = flags
        samples.withUnsafeMutableBytes { bytes in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 1, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress
            ))
            context.processSourceAudio(buffer: &list, requestedFrames: 1024, returnedFrames: &returned,
                                       flags: &outputFlags, status: status)
        }
        return (samples, returned, outputFlags)
    }
}
