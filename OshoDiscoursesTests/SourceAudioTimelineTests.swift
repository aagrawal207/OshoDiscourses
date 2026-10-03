import AVFoundation
import Testing
@testable import OshoDiscourses

struct SourceAudioTimelineTests {
    @Test func sequentialRangesAndChangingPlaybackSpeedsRemainContinuous() {
        var timeline = SourceAudioTimeline()
        var start = CMTime.zero
        for sourceFrames: Int64 in [1024, 1024, 512, 512, 2048, 2048, 512, 1024] {
            // A 1024-frame output callback can represent different asset durations.
            let range = CMTimeRange(start: start, duration: CMTime(value: sourceFrames, timescale: 22_050))
            let result = timeline.consume(range, sampleRate: 22_050)
            #expect(result.validRange)
            #expect(!result.requiresReset && !result.timedDiscontinuity)
            start = CMTimeRangeGetEnd(range)
        }
    }

    @Test func rationalTimebaseRoundingDoesNotLookLikeASeek() {
        var timeline = SourceAudioTimeline()
        for index in 0..<100 {
            let exactStart = CMTime(value: Int64(index * 1024), timescale: 22_050)
            let scale: CMTimeScale = index.isMultiple(of: 2) ? 600 : 48_000
            let range = CMTimeRange(
                start: CMTime(seconds: exactStart.seconds, preferredTimescale: scale),
                duration: CMTime(seconds: 1024.0 / 22_050, preferredTimescale: scale)
            )
            #expect(!timeline.consume(range, sampleRate: 22_050).requiresReset)
        }
    }

    @Test func unflaggedForwardAndBackwardSeeksAreDetectedOnce() {
        var timeline = SourceAudioTimeline()
        let duration = CMTime(value: 1024, timescale: 22_050)
        _ = timeline.consume(CMTimeRange(start: .zero, duration: duration), sampleRate: 22_050)
        let forward = timeline.consume(CMTimeRange(start: CMTime(seconds: 20, preferredTimescale: 22_050), duration: duration), sampleRate: 22_050)
        #expect(forward.requiresReset && forward.timedDiscontinuity && forward.gapSeconds > 19)
        let backwardsRange = CMTimeRange(start: CMTime(seconds: 5, preferredTimescale: 22_050), duration: duration)
        let backward = timeline.consume(backwardsRange, sampleRate: 22_050)
        #expect(backward.requiresReset && backward.timedDiscontinuity && backward.gapSeconds < -15)
        let next = CMTimeRange(start: CMTimeRangeGetEnd(backwardsRange), duration: duration)
        #expect(!timeline.consume(next, sampleRate: 22_050).requiresReset)
    }

    @Test func epochChangesAreBoundariesEvenWhenNumericTimesMeet() {
        var timeline = SourceAudioTimeline()
        let duration = CMTime(value: 1024, timescale: 22_050)
        _ = timeline.consume(CMTimeRange(start: .zero, duration: duration), sampleRate: 22_050)
        let range = CMTimeRange(start: CMTime(value: 1024, timescale: 22_050, flags: .valid, epoch: 7), duration: duration)
        #expect(timeline.consume(range, sampleRate: 22_050).timedDiscontinuity)
        #expect(!timeline.consume(CMTimeRange(start: CMTimeRangeGetEnd(range), duration: duration), sampleRate: 22_050).requiresReset)
    }

    @Test func invalidTimingIsNotComparedAsZeroAndCannotBridgeUnknownAudio() {
        let invalidRanges: [CMTimeRange] = [
            .invalid, .zero,
            CMTimeRange(start: .indefinite, duration: CMTime(value: 1, timescale: 1)),
            CMTimeRange(start: .zero, duration: .positiveInfinity),
            CMTimeRange(start: .zero, duration: CMTime(value: -1, timescale: 1))
        ]
        let duration = CMTime(value: 1024, timescale: 22_050)
        for invalid in invalidRanges {
            var timeline = SourceAudioTimeline()
            _ = timeline.consume(CMTimeRange(start: .zero, duration: duration), sampleRate: 22_050)
            let loss = timeline.consume(invalid, sampleRate: 22_050)
            #expect(!loss.validRange && loss.requiresReset && !loss.timedDiscontinuity)
            #expect(!timeline.consume(invalid, sampleRate: 22_050).requiresReset)
            let restored = timeline.consume(CMTimeRange(start: duration, duration: duration), sampleRate: 22_050)
            #expect(restored.validRange && restored.requiresReset && !restored.timedDiscontinuity)
        }
    }

    @Test func explicitStartReanchorsWithoutASecondInferredBoundary() {
        var timeline = SourceAudioTimeline()
        let duration = CMTime(value: 1024, timescale: 22_050)
        _ = timeline.consume(CMTimeRange(start: .zero, duration: duration), sampleRate: 22_050)
        let result = timeline.consume(CMTimeRange(start: CMTime(value: 20, timescale: 1), duration: duration),
                                      sampleRate: 22_050, startsStream: true)
        #expect(result.validRange && !result.requiresReset)
    }

    @Test(arguments: [NoiseReductionMode.rnnoise, .deepFilterNet])
    func timeJumpKeepsWholeStereoBufferRawAndDiscardsOldHistory(mode: NoiseReductionMode) async throws {
        let processor = NoiseReductionProcessor()
        processor.configure(mode: mode, wetMix: 0.5, intensity: 0.7, attenuationLimitDb: 12, voiceFocus: .focus, outputGain: 2)
        let context = try #require(processor.makeTapContext(generation: 9))
        context.prepare(channelCount: 2, maxFrames: 1024, sampleRate: 22_050)
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            let state = processor.diagnosticsSnapshot()
            if state.isPrepared && (mode != .deepFilterNet || state.deepFilterStatus.isActive) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(processor.diagnosticsSnapshot().isPrepared)
        let duration = CMTime(value: 1024, timescale: 22_050)
        for index in 0..<20 {
            let range = CMTimeRange(start: CMTime(value: Int64(index * 1024), timescale: 22_050), duration: duration)
            _ = send(context, value: 0.4, range: range)
        }
        let seek = CMTimeRange(start: CMTime(value: 20, timescale: 1), duration: duration)
        let first = send(context, value: 0.2, range: seek)
        #expect(first.flags & kMTAudioProcessingTapFlag_StartOfStream != 0)
        #expect(first.samples.enumerated().allSatisfy { $0.element == ($0.offset.isMultiple(of: 2) ? 0.2 : -0.1) })
        while processor.diagnosticsSnapshot().resetPending, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(!processor.diagnosticsSnapshot().resetPending)
        var next = CMTimeRangeGetEnd(seek)
        for _ in 0..<10 {
            let range = CMTimeRange(start: next, duration: duration)
            #expect(send(context, value: 0, range: range).samples.allSatisfy { abs($0) < 0.0001 })
            next = CMTimeRangeGetEnd(range)
        }
        let state = processor.diagnosticsSnapshot()
        #expect(state.tapGeneration == 9)
        #expect(state.sourceTimeDiscontinuities == 1)
        #expect(state.sourceTimeResets == 1)
        #expect(state.sourceDiscontinuities == 1)
        #expect(state.streamResets == 1)
        #expect(state.invalidSourceTimeRanges == 0)
    }

    private func send(_ context: NoiseReductionTapContext, value: Float, range: CMTimeRange) -> (samples: [Float], flags: MTAudioProcessingTapFlags) {
        var samples = (0..<2048).map { $0.isMultiple(of: 2) ? value : -value * 0.5 }
        var frames = 1024
        var flags: MTAudioProcessingTapFlags = 0
        samples.withUnsafeMutableBytes { bytes in
            var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
            context.processSourceAudio(buffer: &buffers, requestedFrames: 1024, returnedFrames: &frames,
                                       flags: &flags, status: noErr, sourceTimeRange: range)
        }
        return (samples, flags)
    }
}
