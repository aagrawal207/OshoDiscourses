import AVFoundation
import Foundation
import MediaToolbox
import Testing
@testable import OshoDiscourses

@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct AudioPlayerIntegrationTests {
    @Test func reductionStrengthAndVoiceFocusRemainIndependentAcrossMethods() {
        let service = AudioPlayerService(settings: nil, connectsToSystem: false)
        defer { service.stop() }
        service.noiseReductionMode = .rnnoise
        service.denoiseStrength = .light
        service.noiseReductionMode = .deepFilterNet
        service.voiceFocusPreset = .strong
        service.isNoiseReductionEnabled = true

        #expect(service.denoiseStrength == .light)
        #expect(service.voiceFocusPreset == .strong)
        #expect(service.noiseReductionAccessibilityValue.contains("Best Quality, Light noise reduction"))
        #expect(service.noiseReductionAccessibilityValue.contains("quiet speech Extra Lift"))
        #expect(service.audioProcessingStatus == .waitingForPlayback)
        #expect(!service.isBoostAvailable)
    }

    @Test(arguments: [NoiseReductionMode.deepFilterNet, .rnnoise])
    func localStereoPlaybackProcessesAudioAndKeepsTapForParameterChanges(mode: NoiseReductionMode) async throws {
        let audio = try PlaybackAudioFixture(seconds: 60)
        defer { audio.remove() }
        let source = try AVAudioFile(forReading: audio.url)
        #expect(source.fileFormat.sampleRate == 22_050)
        #expect(source.fileFormat.channelCount == 2)
        let processor = NoiseReductionProcessor()
        let nativePlayer = AVPlayer()
        var mixBuilds = 0
        let service = AudioPlayerService(
            settings: nil, connectsToSystem: false, noiseProcessor: processor,
            makePlayer: { nativePlayer },
            makeAudioMix: { processor, track, generation in
                mixBuilds += 1
                return processor.createAudioMix(for: track, generation: generation)
            }
        )
        defer { service.stop() }
        service.noiseReductionMode = mode
        service.isNoiseReductionEnabled = true
        service.play(localURL: audio.url, id: "local-stereo", title: "Local stereo", series: "Integration")

        try await waitUntil("local audio reaches the native denoiser", timeout: .seconds(30)) {
            service.audioProcessingStatus == .active
                && nativePlayer.timeControlStatus == .playing
                && processor.diagnosticsSnapshot().processedBuffers >= 8
        }
        let item = try #require(nativePlayer.currentItem)
        let mix = try #require(item.audioMix)
        let tap = try #require(mix.inputParameters.first?.audioTapProcessor)
        let firstGeneration = try #require(processor.diagnosticsSnapshot().tapGeneration)
        #expect(mixBuilds == 1)
        #expect(processor.diagnosticsSnapshot().isPrepared)
        #expect(service.isBoostAvailable)
        #expect(processor.diagnosticsSnapshot().invalidBuffers == 0)
        #expect(processor.diagnosticsSnapshot().sourceReadFailures == 0)

        let enabled = service.isNoiseReductionEnabled
        let selectedMode = service.noiseReductionMode
        let strength = service.denoiseStrength
        let focus = service.voiceFocusPreset
        let beforeParameters = processor.diagnosticsSnapshot()
        service.isNoiseReductionEnabled = enabled
        service.noiseReductionMode = selectedMode
        service.denoiseStrength = strength
        service.voiceFocusPreset = focus
        service.denoiseStrength = .light
        service.voiceFocusPreset = .strong
        service.setVolume(1.5)

        #expect(item.audioMix === mix)
        #expect(item.audioMix?.inputParameters.first?.audioTapProcessor === tap)
        #expect(processor.diagnosticsSnapshot().tapGeneration == firstGeneration)
        #expect(mixBuilds == 1)
        #expect(service.noiseReductionAccessibilityValue.contains("Light noise reduction"))
        if mode == .deepFilterNet {
            #expect(!service.noiseReductionAccessibilityValue.contains("dB"))
            #expect(service.noiseReductionAccessibilityValue.contains("quiet speech Extra Lift"))
        }
        try await waitUntil("processing continues after parameter changes") {
            processor.diagnosticsSnapshot().processedBuffers > beforeParameters.processedBuffers + 4
        }

        let beforeModeChange = processor.diagnosticsSnapshot().processedBuffers
        service.noiseReductionMode = mode == .deepFilterNet ? .rnnoise : .deepFilterNet
        #expect(item.audioMix === mix)
        #expect(mixBuilds == 1)
        #expect(processor.diagnosticsSnapshot().tapGeneration == firstGeneration)
        try await waitUntil("the other native method processes through the same tap", timeout: .seconds(30)) {
            service.audioProcessingStatus == .active
                && processor.diagnosticsSnapshot().processedBuffers > beforeModeChange + 4
        }

        let beforeSeek = processor.diagnosticsSnapshot()
        let seekTarget: TimeInterval = nativePlayer.currentTime().seconds < 15 ? 20 : 5
        service.seek(to: seekTarget)
        try await waitUntil("seek lands and processing resumes") {
            nativePlayer.currentTime().seconds >= seekTarget
                && nativePlayer.currentTime().seconds < seekTarget + 2
                && service.audioProcessingStatus == .active
                && processor.diagnosticsSnapshot().processedBuffers > beforeSeek.processedBuffers + 4
        }
        #expect(item.audioMix === mix)
        let afterSeek = processor.diagnosticsSnapshot()
        #expect(afterSeek.sourceTimeRanges > beforeSeek.sourceTimeRanges)
        // CAF seeks can report invalid timing during the boundary. Both losing
        // and reacquiring a trusted timeline must fence carried processing state.
        #expect(afterSeek.sourceTimeResets > beforeSeek.sourceTimeResets,
                "asset-time reset required: valid jumps \(beforeSeek.sourceTimeDiscontinuities)->\(afterSeek.sourceTimeDiscontinuities), invalid ranges \(beforeSeek.invalidSourceTimeRanges)->\(afterSeek.invalidSourceTimeRanges)")
        #expect(afterSeek.sourceDiscontinuities > beforeSeek.sourceDiscontinuities)
        #expect(afterSeek.streamResets > beforeSeek.streamResets)
        print("\(mode.rawValue) seek boundary: timed resets \(beforeSeek.sourceTimeResets)->\(afterSeek.sourceTimeResets), invalid ranges \(beforeSeek.invalidSourceTimeRanges)->\(afterSeek.invalidSourceTimeRanges), stream resets \(beforeSeek.streamResets)->\(afterSeek.streamResets)")

        service.isNoiseReductionEnabled = false
        #expect(item.audioMix == nil)
        #expect(service.audioProcessingStatus == .off)
        #expect(!service.isAudioProcessingAttached)
        #expect(!service.isBoostAvailable)
        #expect(service.volume == 1.5)
        #expect(processor.diagnosticsSnapshot().tapGeneration == nil)
        #expect(!processor.diagnosticsSnapshot().isPrepared)

        service.isNoiseReductionEnabled = true
        try await waitUntil("a replacement tap processes the current item", timeout: .seconds(30)) {
            mixBuilds == 2 && service.audioProcessingStatus == .active
                && processor.diagnosticsSnapshot().processedBuffers >= 4
        }
        let replacementTap = try #require(item.audioMix?.inputParameters.first?.audioTapProcessor)
        let replacementContext = Unmanaged<NoiseReductionTapContext>
            .fromOpaque(MTAudioProcessingTapGetStorage(replacementTap)).takeUnretainedValue()
        #expect(replacementTap !== tap)
        #expect(processor.diagnosticsSnapshot().tapGeneration != firstGeneration)

        let itemID = ObjectIdentifier(item)
        let generation = service.playbackGeneration
        service.stop()
        service.handleItemStatusChange(for: itemID, generation: generation)
        replacementContext.prepare(channelCount: 2, maxFrames: 4096, sampleRate: 22_050)
        send(try audio.buffer(frames: 64), through: replacementContext, status: -50)
        service.refreshAudioProcessingStatus()
        #expect(replacementContext.isRetired)
        #expect(processor.diagnosticsSnapshot().tapGeneration == nil)
        #expect(nativePlayer.currentItem == nil)
        #expect(item.audioMix == nil)
        #expect(service.currentTrackId == nil)
        #expect(!service.isPlaying)
        #expect(!service.isAudioProcessingAttached)
        #expect(!service.isBoostAvailable)
        #expect(service.deepFilterStatus == .idle)
        #expect(service.audioProcessingStatus == .waitingForPlayback)
    }

    @Test(arguments: [
        AudioPlayerService.AudioMixFailure.trackLoading,
        .noAudioTrack,
        .tapCreation,
    ])
    func setupFailuresAreVisibleAndNeverEnableBoost(failure: AudioPlayerService.AudioMixFailure) async throws {
        let audio = try PlaybackAudioFixture(seconds: 10)
        defer { audio.remove() }
        let service = AudioPlayerService(
            settings: nil, connectsToSystem: false,
            loadAudioTrack: { item in
                if failure == .trackLoading { throw URLError(.cannotDecodeContentData) }
                if failure == .noAudioTrack { return nil }
                return try await item.asset.loadTracks(withMediaType: .audio).first
            },
            makeAudioMix: { _, _, _ in nil }
        )
        defer { service.stop() }
        service.noiseReductionMode = .cadence
        service.setVolume(3)
        service.isNoiseReductionEnabled = true
        service.play(localURL: audio.url, id: "setup-failure", title: "Setup", series: "Integration")

        try await waitUntil("the specific setup failure is surfaced") {
            service.audioProcessingStatus == .setupFailed(failure)
        }
        #expect(service.audioProcessingStatus.isIssue)
        #expect(service.noiseReductionAccessibilityValue.contains("Enhancement unavailable"))
        #expect(!service.isAudioProcessingAttached)
        #expect(!service.isBoostAvailable)
        service.isNoiseReductionEnabled = false
        #expect(service.audioProcessingStatus == .off)
    }

    @Test(arguments: [true, false])
    func supersededAudioTrackLoadsCannotAttachOrReportFailure(fails: Bool) async throws {
        let audio = try PlaybackAudioFixture(seconds: 30)
        defer { audio.remove() }
        var pending: CheckedContinuation<Void, Error>?
        var firstLoadFinished = false
        var loads = 0
        var builds = 0
        let nativePlayer = AVPlayer()
        let service = AudioPlayerService(
            settings: nil, connectsToSystem: false,
            makePlayer: { nativePlayer },
            loadAudioTrack: { item in
                loads += 1
                if loads == 1 {
                    defer { firstLoadFinished = true }
                    let track = try await item.asset.loadTracks(withMediaType: .audio).first
                    try await withCheckedThrowingContinuation { pending = $0 }
                    return track
                }
                return try await item.asset.loadTracks(withMediaType: .audio).first
            },
            makeAudioMix: { processor, track, generation in
                builds += 1
                return processor.createAudioMix(for: track, generation: generation)
            }
        )
        defer {
            pending?.resume(throwing: CancellationError())
            service.stop()
        }
        service.noiseReductionMode = .cadence
        service.isNoiseReductionEnabled = true
        service.play(localURL: audio.url, id: "old", title: "Old", series: "Integration")
        let oldItem = try #require(nativePlayer.currentItem)
        let oldGeneration = service.playbackGeneration
        try await waitUntil("first track load is suspended") { pending != nil }

        service.play(localURL: audio.url, id: "new", title: "New", series: "Integration")
        try await waitUntil("replacement item gets its own working tap") {
            service.audioProcessingStatus == .active
        }
        let currentMix = try #require(nativePlayer.currentItem?.audioMix)
        let continuation = try #require(pending)
        pending = nil
        if fails {
            continuation.resume(throwing: URLError(.cannotDecodeContentData))
        } else {
            continuation.resume()
        }
        try await waitUntil("superseded loader has returned") { firstLoadFinished }
        service.handleItemStatusChange(for: ObjectIdentifier(oldItem), generation: oldGeneration)
        #expect(service.currentTrackId == "new")
        #expect(service.currentTitle == "New")
        #expect(nativePlayer.currentItem?.audioMix === currentMix)
        #expect(oldItem.audioMix == nil)
        #expect(builds == 1)
        #expect(service.audioProcessingStatus == .active)
    }

    @Test func seekWithoutAPlayerIsKeptForTheNextResume() {
        let service = AudioPlayerService(settings: nil, connectsToSystem: false)
        service.seek(to: 42)
        #expect(service.currentTime == 0, "nothing loaded: nothing to remember")
        service.currentTrackId = "loaded"
        service.seek(to: 42)
        #expect(service.currentTime == 42)
    }

    @Test func setPlayingIsIdempotent() async throws {
        let audio = try PlaybackAudioFixture(seconds: 30)
        defer { audio.remove() }
        let nativePlayer = AVPlayer()
        let service = AudioPlayerService(settings: nil, connectsToSystem: false, makePlayer: { nativePlayer })
        defer { service.stop() }
        service.setPlaying(true)
        #expect(service.currentTrackId == nil, "nothing loaded: nothing to start")

        service.play(localURL: audio.url, id: "talk", title: "Talk", series: "Integration")
        try await waitUntil("playback starts") { service.isPlaying }
        service.setPlaying(true)
        #expect(service.isPlaying)
        service.setPlaying(false)
        #expect(!service.isPlaying)
        service.setPlaying(false)
        #expect(!service.isPlaying, "a repeated pause must not resume")
        service.setPlaying(true)
        try await waitUntil("playback resumes") { service.isPlaying }
    }

    @Test func pauseSavesThePositionAndPlayStartsANewStretch() async throws {
        let audio = try PlaybackAudioFixture(seconds: 30)
        defer { audio.remove() }
        let suite = "player-session-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = PlaybackStateService(defaults: defaults, recordListeningTime: { _ in }, saveListeningStats: {})
        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        state.savePosition(discourseId: "talk", position: 8, duration: 30, savedAt: earlier)
        let nativePlayer = AVPlayer()
        let service = AudioPlayerService(settings: nil, connectsToSystem: false, makePlayer: { nativePlayer })
        service.playbackStateService = state
        defer { service.stop() }

        service.play(localURL: audio.url, id: "talk", title: "Talk", series: "Integration")
        try await waitUntil("playback starts") { service.isPlaying }
        let first = try #require(service.playSession)
        #expect(first.discourseID == "talk")
        #expect(abs(first.startPosition - 8) < 0.5)
        #expect(first.savedBefore == earlier)

        service.seek(to: 20)
        service.setPlaying(false)
        #expect(state.getPosition(discourseId: "talk") == 20)
        let pausedAt = try #require(state.lastSaved(discourseId: "talk"))
        #expect(pausedAt > earlier)

        service.setPlaying(true)
        try await waitUntil("playback resumes") { service.isPlaying }
        let second = try #require(service.playSession)
        #expect(second.startedAt >= first.startedAt)
        #expect(second.savedBefore == pausedAt)
        #expect(abs(second.startPosition - 20) < 0.5)
    }

    @Test func cloudProgressMovesAPausedLoadedTalk() async throws {
        let audio = try PlaybackAudioFixture(seconds: 30)
        defer { audio.remove() }
        let suite = "player-cloud-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = PlaybackStateService(defaults: defaults, recordListeningTime: { _ in }, saveListeningStats: {})
        let nativePlayer = AVPlayer()
        let service = AudioPlayerService(settings: nil, connectsToSystem: false, makePlayer: { nativePlayer })
        service.playbackStateService = state
        state.attach(to: service)
        defer { service.stop() }

        service.play(localURL: audio.url, id: "talk", title: "Talk", series: "Integration")
        try await waitUntil("playback starts") { service.isPlaying }
        service.seek(to: 5)
        service.setPlaying(false)
        var snapshot = CloudSnapshot()
        snapshot.positions = ["talk": 25]
        _ = state.mergeCloudSnapshot(snapshot)
        #expect(service.currentTime == 25, "the paused player follows, so its autosave keeps 25")
        state.saveCurrentPosition()
        #expect(state.getPosition(discourseId: "talk") == 25)
    }

    @Test func seekWhileLoadingWinsOverTheSavedPosition() async throws {
        let audio = try PlaybackAudioFixture(seconds: 30)
        defer { audio.remove() }
        let suite = "player-loading-seek-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = PlaybackStateService(defaults: defaults, recordListeningTime: { _ in }, saveListeningStats: {})
        state.savePosition(discourseId: "talk", position: 8, duration: 30)
        let nativePlayer = AVPlayer()
        let service = AudioPlayerService(settings: nil, connectsToSystem: false, makePlayer: { nativePlayer })
        service.playbackStateService = state
        defer { service.stop() }

        service.play(localURL: audio.url, id: "talk", title: "Talk", series: "Integration")
        // A bookmark chosen from CarPlay or the Watch before the item is ready.
        service.seekWithHistory(to: 20)
        #expect(service.currentTime == 20)
        try await waitUntil("the item is ready") { service.duration > 0 }
        try await waitUntil("the chosen position holds", timeout: .seconds(3)) { abs(service.currentTime - 20) < 0.5 }
    }

    @Test func restoringTheVeryEndDoesNotFinishTheTalk() async throws {
        let audio = try PlaybackAudioFixture(seconds: 30)
        defer { audio.remove() }
        let suite = "player-end-restore-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = PlaybackStateService(defaults: defaults, recordListeningTime: { _ in }, saveListeningStats: {})
        let nativePlayer = AVPlayer()
        let service = AudioPlayerService(settings: nil, connectsToSystem: false, makePlayer: { nativePlayer })
        service.playbackStateService = state
        defer { service.stop() }

        service.playQueue(items: [.init(id: "talk", url: audio.url, title: "Talk", series: "Integration")], resumeAt: 30)
        try await waitUntil("the item is ready") { service.duration > 0 }
        #expect(service.currentTime <= service.duration - 0.5)
        #expect(service.currentTrackId == "talk")
        #expect(!state.isCompleted("talk"))
    }

    @Test func retryAfterAFailedLoadResumesFromTheSavedPosition() async throws {
        let audio = try PlaybackAudioFixture(seconds: 30)
        defer { audio.remove() }
        let suite = "player-retry-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = PlaybackStateService(defaults: defaults, recordListeningTime: { _ in }, saveListeningStats: {})
        state.savePosition(discourseId: "talk", position: 12, duration: 30)
        let broken = audio.directory.appendingPathComponent("talk.caf")
        try Data(repeating: 0x5A, count: 4096).write(to: broken)
        let nativePlayer = AVPlayer()
        let service = AudioPlayerService(settings: nil, connectsToSystem: false, makePlayer: { nativePlayer })
        service.playbackStateService = state
        defer { service.stop() }

        service.play(localURL: broken, id: "talk", title: "Talk", series: "Integration")
        try await waitUntil("the unreadable item fails") { nativePlayer.currentItem?.status == .failed }
        #expect(service.currentTime == 0)
        // The file becomes readable, e.g. a download finished replacing it.
        try FileManager.default.removeItem(at: broken)
        try FileManager.default.copyItem(at: audio.url, to: broken)
        service.resumePlayback()
        try await waitUntil("the retried item is ready") { nativePlayer.currentItem?.status == .readyToPlay }
        // Short deadline: restarting at 0 would also reach 12 s by simply playing.
        try await waitUntil("the saved position is restored", timeout: .seconds(3)) { abs(service.currentTime - 12) < 0.5 }
    }

    @Test func autoAdvanceDoesNotSaveTheFinishedTalkAgain() async throws {
        let audio = try PlaybackAudioFixture(seconds: 30)
        defer { audio.remove() }
        let suite = "player-advance-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = PlaybackStateService(defaults: defaults, recordListeningTime: { _ in }, saveListeningStats: {})
        let second = audio.directory.appendingPathComponent("second.caf")
        try FileManager.default.copyItem(at: audio.url, to: second)
        let nativePlayer = AVPlayer()
        let service = AudioPlayerService(
            settings: nil, connectsToSystem: false,
            originalPlaybackActions: .init(
                autoPlayNext: true, smartDownload: { _ in }, smartDelete: { _ in }, nextDownloadedItem: { _ in nil }
            ),
            makePlayer: { nativePlayer }
        )
        service.playbackStateService = state
        defer { service.stop() }

        service.playQueue(items: [
            .init(id: "first", url: audio.url, title: "First", series: "Integration"),
            .init(id: "second", url: second, title: "Second", series: "Integration"),
        ])
        try await waitUntil("the first talk is ready") { service.duration > 0 }
        service.seek(to: 20)
        service.skipForward(30)
        #expect(service.currentTrackId == "second")
        #expect(state.isCompleted("first"))
        #expect(state.getPosition(discourseId: "first") == 0)
    }

    @Test func stoppingDuringTrackLoadPreventsLateAttachment() async throws {
        let audio = try PlaybackAudioFixture(seconds: 10)
        defer { audio.remove() }
        var pending: CheckedContinuation<Void, Error>?
        var loadFinished = false
        var builds = 0
        let nativePlayer = AVPlayer()
        let service = AudioPlayerService(
            settings: nil, connectsToSystem: false,
            makePlayer: { nativePlayer },
            loadAudioTrack: { item in
                defer { loadFinished = true }
                let track = try await item.asset.loadTracks(withMediaType: .audio).first
                try await withCheckedThrowingContinuation { pending = $0 }
                return track
            },
            makeAudioMix: { _, _, _ in
                builds += 1
                return AVMutableAudioMix()
            }
        )
        defer {
            pending?.resume(throwing: CancellationError())
            service.stop()
        }
        service.isNoiseReductionEnabled = true
        service.play(localURL: audio.url, id: "stopped", title: "Stopped", series: "Integration")
        let item = try #require(nativePlayer.currentItem)
        let generation = service.playbackGeneration
        try await waitUntil("track loading has started") { pending != nil }
        service.stop()
        let continuation = try #require(pending)
        pending = nil
        continuation.resume()
        try await waitUntil("cancelled loader has returned") { loadFinished }
        service.handleItemStatusChange(for: ObjectIdentifier(item), generation: generation)
        #expect(builds == 0)
        #expect(item.audioMix == nil)
        #expect(service.currentTrackId == nil)
        #expect(!service.isPlaying)
        #expect(!service.isBoostAvailable)
        #expect(service.audioProcessingStatus == .waitingForPlayback)
    }

    @Test func readyModelRequiresNewBuffersAndPreparedTapToEnableBoost() async throws {
        let audio = try PlaybackAudioFixture(seconds: 30)
        defer { audio.remove() }
        let processor = NoiseReductionProcessor()
        var context: NoiseReductionTapContext?
        let nativePlayer = AVPlayer()
        let service = AudioPlayerService(
            settings: nil, connectsToSystem: false, noiseProcessor: processor,
            makePlayer: { nativePlayer },
            makeAudioMix: { processor, _, generation in
                guard let tap = processor.makeTapContext(generation: generation) else { return nil }
                context = tap
                tap.prepare(channelCount: 2, maxFrames: 4096, sampleRate: 22_050)
                return AVMutableAudioMix()
            }
        )
        defer { service.stop() }
        service.isNoiseReductionEnabled = true
        service.play(localURL: audio.url, id: "no-tap", title: "No tap", series: "Integration")
        try await waitUntil("item plays with a prepared model but no processed buffers", timeout: .seconds(30)) {
            let snapshot = processor.diagnosticsSnapshot()
            return snapshot.isPrepared && snapshot.deepFilterStatus == .active
                && nativePlayer.timeControlStatus == .playing && service.isAudioProcessingAttached
        }
        let tap = try #require(context)
        service.refreshAudioProcessingStatus()
        #expect(service.deepFilterStatus == .active)
        #expect(service.audioProcessingStatus == .modelReady)
        #expect(!service.isBoostAvailable)
        try await waitUntil("missing callbacks are reported") {
            service.audioProcessingStatus == .waitingForAudio
        }
        #expect(processor.diagnosticsSnapshot().processedBuffers == 0)

        send(try audio.buffer(frames: 4096), through: tap)
        service.refreshAudioProcessingStatus()
        #expect(processor.diagnosticsSnapshot().processedBuffers == 1)
        #expect(service.audioProcessingStatus == .active)
        #expect(service.isBoostAvailable)

        tap.unprepare()
        service.refreshAudioProcessingStatus()
        #expect(!processor.diagnosticsSnapshot().isPrepared)
        #expect(service.audioProcessingStatus == .preparing)
        #expect(!service.isBoostAvailable)
        tap.prepare(channelCount: 2, maxFrames: 4096, sampleRate: 22_050)
        try await waitUntil("the same tap is prepared again") { processor.diagnosticsSnapshot().isPrepared }
        service.refreshAudioProcessingStatus()
        #expect(processor.diagnosticsSnapshot().processedBuffers == 1)
        #expect(service.audioProcessingStatus == .modelReady)
        #expect(!service.isBoostAvailable)
    }

    @Test func sourceReadFailureIsVisibleAndDisableRetiresItsTap() async throws {
        let audio = try PlaybackAudioFixture(seconds: 10)
        defer { audio.remove() }
        let processor = NoiseReductionProcessor()
        var context: NoiseReductionTapContext?
        let service = AudioPlayerService(
            settings: nil, connectsToSystem: false, noiseProcessor: processor,
            makeAudioMix: { processor, _, generation in
                guard let tap = processor.makeTapContext(generation: generation) else { return nil }
                context = tap
                tap.prepare(channelCount: 2, maxFrames: 4096, sampleRate: 22_050)
                return AVMutableAudioMix()
            }
        )
        defer { service.stop() }
        service.noiseReductionMode = .cadence
        service.isNoiseReductionEnabled = true
        service.play(localURL: audio.url, id: "source-error", title: "Source", series: "Integration")
        try await waitUntil("managed tap is prepared") {
            service.isAudioProcessingAttached && processor.diagnosticsSnapshot().isPrepared
        }
        let tap = try #require(context)
        send(try audio.buffer(frames: 64), through: tap, status: -50)
        service.refreshAudioProcessingStatus()
        #expect(processor.diagnosticsSnapshot().sourceReadFailures == 1)
        #expect(service.audioProcessingStatus == .sourceError)
        #expect(!service.isBoostAvailable)
        service.isNoiseReductionEnabled = false
        #expect(tap.isRetired)
        #expect(processor.diagnosticsSnapshot().tapGeneration == nil)
        #expect(service.audioProcessingStatus == .off)
        #expect(!service.isAudioProcessingAttached)
    }

    @Test func retiredTapCannotMakeReplacementActiveOrReportItsErrors() async throws {
        let audio = try PlaybackAudioFixture(seconds: 30)
        defer { audio.remove() }
        let processor = NoiseReductionProcessor()
        var contexts: [NoiseReductionTapContext] = []
        let nativePlayer = AVPlayer()
        let service = AudioPlayerService(
            settings: nil, connectsToSystem: false, noiseProcessor: processor,
            makePlayer: { nativePlayer },
            makeAudioMix: { processor, _, generation in
                guard let context = processor.makeTapContext(generation: generation) else { return nil }
                contexts.append(context)
                context.prepare(channelCount: 2, maxFrames: 4096, sampleRate: 22_050)
                return AVMutableAudioMix()
            }
        )
        defer { service.stop() }
        service.noiseReductionMode = .cadence
        service.isNoiseReductionEnabled = true
        service.play(localURL: audio.url, id: "old", title: "Old", series: "Integration")
        try await waitUntil("first managed tap is ready") {
            contexts.count == 1 && processor.diagnosticsSnapshot().isPrepared
                && nativePlayer.timeControlStatus == .playing
        }
        let old = try #require(contexts.first)
        send(try audio.buffer(frames: 64), through: old)
        service.refreshAudioProcessingStatus()
        #expect(service.audioProcessingStatus == .active)

        service.play(localURL: audio.url, id: "new", title: "New", series: "Integration")
        try await waitUntil("replacement tap is ready without any processed buffers") {
            contexts.count == 2 && processor.diagnosticsSnapshot().isPrepared
                && nativePlayer.timeControlStatus == .playing
        }
        let current = contexts[1]
        #expect(old.isRetired)
        #expect(current.generation > old.generation)
        #expect(processor.diagnosticsSnapshot().processedBuffers == 0)
        service.refreshAudioProcessingStatus()
        #expect(!service.audioProcessingStatus.isActive)
        #expect(!service.isBoostAvailable)

        old.prepare(channelCount: 2, maxFrames: 4096, sampleRate: 48_000)
        old.unprepare()
        send(try audio.buffer(frames: 64), through: old)
        send(try audio.buffer(frames: 64), through: old, status: -50)
        processor.retireAudioMix(generation: old.generation)
        service.refreshAudioProcessingStatus()
        let snapshot = processor.diagnosticsSnapshot()
        #expect(snapshot.tapGeneration == current.generation)
        #expect(snapshot.isPrepared)
        #expect(snapshot.processedBuffers == 0)
        #expect(snapshot.sourceReadFailures == 0)
        #expect(!service.audioProcessingStatus.isActive)
        #expect(service.audioProcessingStatus != .sourceError)
        #expect(service.audioProcessingStatus != .unsupportedFormat)

        send(try audio.buffer(frames: 64), through: current)
        service.refreshAudioProcessingStatus()
        #expect(processor.diagnosticsSnapshot().processedBuffers == 1)
        #expect(service.audioProcessingStatus == .active)
        service.stop()
        #expect(current.isRetired)
        #expect(processor.diagnosticsSnapshot().tapGeneration == nil)
    }

    @Test func mismatchedTapGenerationCannotReportActive() async throws {
        let audio = try PlaybackAudioFixture(seconds: 30)
        defer { audio.remove() }
        let processor = NoiseReductionProcessor()
        var context: NoiseReductionTapContext?
        let nativePlayer = AVPlayer()
        let service = AudioPlayerService(
            settings: nil, connectsToSystem: false, noiseProcessor: processor,
            makePlayer: { nativePlayer },
            makeAudioMix: { processor, _, generation in
                guard let tap = processor.makeTapContext(generation: generation + 1) else { return nil }
                context = tap
                tap.prepare(channelCount: 2, maxFrames: 4096, sampleRate: 22_050)
                return AVMutableAudioMix()
            }
        )
        defer {
            service.stop()
            if let context { processor.retireAudioMix(generation: context.generation) }
        }
        service.isNoiseReductionEnabled = true
        service.play(localURL: audio.url, id: "wrong-generation", title: "Wrong generation", series: "Integration")
        try await waitUntil("mismatched tap has a ready model", timeout: .seconds(30)) {
            let snapshot = processor.diagnosticsSnapshot()
            return snapshot.isPrepared && snapshot.deepFilterStatus == .active
                && nativePlayer.timeControlStatus == .playing && service.isAudioProcessingAttached
        }
        send(try audio.buffer(frames: 4096), through: try #require(context))
        #expect(processor.diagnosticsSnapshot().processedBuffers == 1)
        service.refreshAudioProcessingStatus()
        #expect(service.audioProcessingStatus == .preparing)
        #expect(service.deepFilterStatus == .idle)
        #expect(!service.isBoostAvailable)
    }

    @Test(arguments: [true, false])
    func mediaResetRecreatesPlayerAndPreservesResumePosition(wasPlaying: Bool) async throws {
        let audio = try PlaybackAudioFixture(seconds: 30)
        defer { audio.remove() }
        var players: [AVPlayer] = []
        let service = AudioPlayerService(
            settings: nil, connectsToSystem: false,
            makePlayer: {
                let player = AVPlayer()
                players.append(player)
                return player
            }
        )
        defer { service.stop() }
        service.noiseReductionMode = .cadence
        service.isNoiseReductionEnabled = true
        service.play(localURL: audio.url, id: "recovery", title: "Recovery", series: "Integration")
        try await waitUntil("initial player is processing") { service.audioProcessingStatus == .active }
        let oldPlayer = try #require(players.first)
        let oldItem = try #require(oldPlayer.currentItem)
        let oldGeneration = service.playbackGeneration
        service.seek(to: 8)
        try await waitUntil("initial player reaches resume position") { oldPlayer.currentTime().seconds >= 8 }
        if !wasPlaying { service.togglePlayPause() }
        let position = service.currentTime

        service.handleMediaServicesReset()
        #expect(oldItem.audioMix == nil)
        if !wasPlaying {
            #expect(players.count == 1)
            #expect(!service.isPlaying)
            #expect(!service.isAudioProcessingAttached)
            #expect(service.audioProcessingStatus == .waitingForPlayback)
            service.resumePlayback()
        }
        try await waitUntil("fresh player restores position and processing") {
            players.count == 2
                && players[1].currentTime().seconds >= position
                && service.audioProcessingStatus == .active
        }
        #expect(players[1] !== oldPlayer)
        #expect(players[1].currentTime().seconds < position + 5)
        service.handleItemStatusChange(for: ObjectIdentifier(oldItem), generation: oldGeneration)
        #expect(service.currentTrackId == "recovery")
        #expect(service.isPlaying)
    }

    private func send(_ buffer: AVAudioPCMBuffer, through context: NoiseReductionTapContext, status: OSStatus = noErr) {
        var returnedFrames = CMItemCount(buffer.frameLength)
        var flags: MTAudioProcessingTapFlags = 0
        context.processSourceAudio(
            buffer: buffer.mutableAudioBufferList, requestedFrames: returnedFrames,
            returnedFrames: &returnedFrames, flags: &flags, status: status
        )
    }

    private func waitUntil(
        _ message: String,
        timeout: Duration = .seconds(15),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(condition(), "Timed out: \(message)")
    }
}

private struct PlaybackAudioFixture {
    let directory: URL
    let url: URL

    init(seconds: Double) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaybackIntegration-\(UUID().uuidString)", isDirectory: true)
        url = directory.appendingPathComponent("stereo-22050.caf")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 2))
            var fileSettings = format.settings
            fileSettings[AVLinearPCMIsNonInterleaved] = false
            let file = try AVAudioFile(forWriting: url, settings: fileSettings)
            defer { file.close() }
            let block = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
            let channels = try #require(block.floatChannelData)
            let frames = Int(seconds * format.sampleRate)
            var offset = 0
            var random: UInt32 = 7
            while offset < frames {
                let count = min(4096, frames - offset)
                block.frameLength = AVAudioFrameCount(count)
                for index in 0..<count {
                    let time = Double(offset + index) / format.sampleRate
                    let speaking = time.truncatingRemainder(dividingBy: 1) < 0.65
                    let voice = speaking ? Float(0.025 * sin(2 * .pi * 170 * time)) : 0
                    random = random &* 1_664_525 &+ 1_013_904_223
                    let noise = Float(Int32(bitPattern: random)) / Float(Int32.max) * 0.002
                    channels[0][index] = voice + noise
                    channels[1][index] = voice * 0.7 + noise * 0.5
                }
                try file.write(from: block)
                offset += count
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func buffer(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let block = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        try file.read(into: block, frameCount: frames)
        return block
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
