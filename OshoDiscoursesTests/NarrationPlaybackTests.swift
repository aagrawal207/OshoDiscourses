import AVFoundation
import Foundation
import MediaPlayer
import Testing
@testable import OshoDiscourses

@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct NarrationPlaybackTests {
    @Test func narrationIDsCannotEnterOriginalPersistenceOrCloudMerge() async throws {
        let fixture = try await NarrationPlaybackFixture()
        defer { fixture.remove() }
        let state = fixture.makePlaybackState()
        let id = AudioPlayerService.narrationTrackID(for: fixture.first.id)
        state.recordPlay(discourseId: fixture.source.id)
        state.savePosition(discourseId: fixture.source.id, position: 32, duration: 90)
        let original = state.exportCloudSnapshot()

        state.savePosition(discourseId: id, position: 18, duration: 60)
        state.recordPlay(discourseId: id)
        state.markCompleted(discourseId: id)
        state.markListenedComplete(discourseId: id)
        let incoming = CloudSnapshot(
            positions: [id: 18], durations: [id: 60], recentlyPlayed: [id],
            completed: [id], listenedCompleted: [id], played: [id]
        )

        #expect(!state.mergeCloudSnapshot(incoming))
        #expect(state.exportCloudSnapshot() == original)
        #expect(state.getPosition(discourseId: id) == 0)
        #expect(state.getDuration(discourseId: id) == 0)
        #expect(!state.isCompleted(id))
        #expect(fixture.defaults.object(forKey: "playbackPosition_" + id) == nil)
        #expect(fixture.defaults.object(forKey: "playbackDuration_" + id) == nil)

        for key in ["recentlyPlayed", "completedDiscourseIDs", "listenedCompletedIDs", "allPlayedDiscourseIDs"] {
            fixture.defaults.set([fixture.source.id, id], forKey: key)
        }
        fixture.defaults.set(18, forKey: "playbackPosition_" + id)
        fixture.defaults.set(60, forKey: "playbackDuration_" + id)
        let restored = fixture.makePlaybackState()
        let snapshot = restored.exportCloudSnapshot()
        #expect(snapshot.recentlyPlayed == [fixture.source.id])
        #expect(snapshot.completed == [fixture.source.id])
        #expect(snapshot.listenedCompleted == [fixture.source.id])
        #expect(snapshot.played == [fixture.source.id])
        #expect(snapshot.positions == [fixture.source.id: 32])
        #expect(snapshot.durations == [fixture.source.id: 90])
    }

    @Test(arguments: [26.0, 87.0, 89.5])
    func switchingOriginalNarrationOriginalPreservesPositionsAndMetadata(originalSeekPosition: TimeInterval) async throws {
        let fixture = try await NarrationPlaybackFixture()
        defer { fixture.remove() }
        let state = fixture.makePlaybackState()
        let native = AVPlayer()
        let service = AudioPlayerService(
            settings: nil, connectsToSystem: false, narrationService: fixture.narrations,
            makePlayer: { native }
        )
        defer { service.stop() }
        fixture.attach(state, to: service)
        var cloudSaves = 0
        state.onProgressSaved = { cloudSaves += 1 }
        state.savePosition(discourseId: fixture.source.id, position: 5, duration: 90)
        service.playQueue(items: [fixture.originalItem, fixture.nextOriginalItem])
        try await waitUntil("original playback resumes") { service.isPlaying && native.currentTime().seconds >= 5 }
        service.togglePlayPause()
        service.seekWithHistory(to: originalSeekPosition)
        try await waitUntil("paused original seek lands") { abs(native.currentTime().seconds - originalSeekPosition) < 0.05 }
        let originalPosition = service.currentTime
        #expect(service.hasPreviousPosition)

        let originalFlushes = cloudSaves
        service.playNarration(fixture.first, url: fixture.firstURL)
        #expect(cloudSaves == originalFlushes + 1)
        #expect(state.getPosition(discourseId: fixture.source.id) == originalPosition)
        #expect(state.getDuration(discourseId: fixture.source.id) == 90)
        #expect(service.currentNarration == fixture.first)
        #expect(service.isPlayingNarration)
        #expect(service.currentDiscourseID == fixture.source.id)
        #expect(service.currentTrackId == "narration:" + fixture.first.id)
        #expect(service.currentTitle == fixture.source.displayTitle)
        #expect(service.currentSeries == fixture.source.seriesName)
        #expect(service.queue.count == 1)
        #expect(service.queue.first?.narration == fixture.first)
        #expect(!service.hasNext && !service.hasPrevious)
        #expect(!service.hasPreviousPosition)
        let originalSnapshot = state.exportCloudSnapshot()
        let savesBeforeNarration = cloudSaves
        try await waitUntil("narration starts") { service.isPlaying && native.currentItem?.status == .readyToPlay }

        let info = service.makeNowPlayingInfo()
        let language = Locale.current.localizedString(forIdentifier: fixture.first.selection.targetLanguage)
            ?? fixture.first.selection.targetLanguage
        #expect(info[MPMediaItemPropertyTitle] as? String == fixture.source.displayTitle)
        #expect(info[MPMediaItemPropertyAlbumTitle] as? String == fixture.source.seriesName)
        #expect(info[MPMediaItemPropertyArtist] as? String == "Osho · \(language) synthesized narration")

        service.seek(to: 8)
        #expect(fixture.narrations.position(for: fixture.first.id) == 8)
        state.saveCurrentPosition()
        #expect(state.exportCloudSnapshot() == originalSnapshot)
        #expect(cloudSaves == savesBeforeNarration)
        #expect(state.getPosition(discourseId: "narration:" + fixture.first.id) == 0)
        let narrationPosition = service.currentTime

        service.returnToOriginal(
            localURL: fixture.originalURL, id: fixture.source.id,
            title: fixture.source.displayTitle, series: fixture.source.seriesName
        )
        #expect(fixture.narrations.position(for: fixture.first.id) == narrationPosition)
        #expect(state.getPosition(discourseId: fixture.source.id) == originalPosition)
        try await waitUntil("original resumes its own timeline") {
            service.isPlaying && native.currentTime().seconds >= originalPosition
        }
        service.togglePlayPause()
        #expect(native.currentTime().seconds < originalPosition + 3)
        #expect(service.currentNarration == nil)
        #expect(!service.isPlayingNarration)
        #expect(service.currentTrackId == fixture.source.id)
        #expect(service.currentDiscourseID == fixture.source.id)
        #expect(service.makeNowPlayingInfo()[MPMediaItemPropertyArtist] as? String == "Osho")
        #expect(state.completedDiscourseIDs.isEmpty)
        #expect(state.listenedCompleted.isEmpty)
        #expect(state.recentlyPlayed == [fixture.source.id])
        #expect(state.allPlayedDiscourseIDs == [fixture.source.id])
    }

    @Test(arguments: [90.0, 105.0])
    func returnToOriginalClampsSavedPositionToAudioEnd(savedPosition: TimeInterval) async throws {
        let fixture = try await NarrationPlaybackFixture()
        defer { fixture.remove() }
        let state = fixture.makePlaybackState()
        let native = AVPlayer()
        let service = AudioPlayerService(
            settings: nil, connectsToSystem: false, narrationService: fixture.narrations,
            makePlayer: { native }
        )
        defer { service.stop() }
        fixture.attach(state, to: service)
        state.savePosition(discourseId: fixture.source.id, position: savedPosition, duration: 90)
        service.playNarration(fixture.first, url: fixture.firstURL)
        try await waitUntil("narration starts") { service.isPlaying }
        service.seek(to: 12)
        service.togglePlayPause()

        service.returnToOriginal(
            localURL: fixture.originalURL, id: fixture.source.id,
            title: fixture.source.displayTitle, series: fixture.source.seriesName
        )
        let item = try #require(native.currentItem)
        try await waitUntil("explicit restoration reaches the bounded original endpoint") {
            native.currentTime().seconds >= 89.95
        }
        #expect(abs(native.currentTime().seconds - 90) < 0.05)
        #expect(service.currentTime <= 90 && service.currentTime >= 89.95)
        #expect((item.asset as? AVURLAsset)?.url == fixture.originalURL)
        #expect(service.currentNarration == nil)
        #expect(fixture.narrations.position(for: fixture.first.id) == 12)
    }

    @Test func savedNarrationRemainsPlayableWithoutTheOriginalDownload() async throws {
        let fixture = try await NarrationPlaybackFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.originalURL)
        let player = AudioPlayerService(settings: nil, connectsToSystem: false, narrationService: fixture.narrations)
        defer { player.stop() }
        player.playNarration(fixture.first, url: fixture.firstURL)
        #expect(player.currentNarration == fixture.first)
        #expect(player.narrationPlaybackFailure == nil)
        #expect(fixture.narrations.audioURL(for: fixture.first) == fixture.firstURL)
    }

    @Test(arguments: [true, false])
    func ordinaryCatalogResumeDropsReplacedRestorationIntent(queued: Bool) async throws {
        let fixture = try await NarrationPlaybackFixture()
        defer { fixture.remove() }
        let state = fixture.makePlaybackState()
        let native = AVPlayer()
        let service = AudioPlayerService(
            settings: nil, connectsToSystem: false, narrationService: fixture.narrations,
            makePlayer: { native }
        )
        defer { service.stop() }
        fixture.attach(state, to: service)
        state.savePosition(discourseId: fixture.source.id, position: 87, duration: 90)
        service.returnToOriginal(
            localURL: fixture.originalURL, id: fixture.source.id,
            title: fixture.source.displayTitle, series: fixture.source.seriesName
        )
        let replaced = try #require(native.currentItem)
        let generation = service.playbackGeneration
        if queued {
            service.playQueue(items: [fixture.originalItem])
        } else {
            service.play(
                localURL: fixture.originalURL, id: fixture.source.id,
                title: fixture.source.displayTitle, series: fixture.source.seriesName
            )
        }
        try await waitUntil("ordinary catalog playback starts") { service.isPlaying }
        service.handleItemStatusChange(for: ObjectIdentifier(replaced), generation: generation)
        #expect(native.currentTime().seconds < 3)
        #expect(service.currentTime < 3)
        #expect(service.currentTrackId == fixture.source.id)
        #expect(state.getPosition(discourseId: fixture.source.id) == 87)
    }

    @Test(arguments: [true, false], [87.0, 89.5])
    func nearEndOriginalRestorationSurvivesMediaReset(beforeReadiness: Bool, savedPosition: TimeInterval) async throws {
        let fixture = try await NarrationPlaybackFixture()
        defer { fixture.remove() }
        let state = fixture.makePlaybackState()
        var players: [AVPlayer] = []
        let service = AudioPlayerService(
            settings: nil, connectsToSystem: false, narrationService: fixture.narrations,
            makePlayer: {
                let player = AVPlayer()
                players.append(player)
                return player
            }
        )
        defer { service.stop() }
        fixture.attach(state, to: service)
        state.savePosition(discourseId: fixture.source.id, position: savedPosition, duration: 90)
        service.returnToOriginal(
            localURL: fixture.originalURL, id: fixture.source.id,
            title: fixture.source.displayTitle, series: fixture.source.seriesName
        )
        if !beforeReadiness {
            try await waitUntil("original restores its last three seconds") {
                service.isPlaying && (players.first?.currentTime().seconds ?? 0) >= savedPosition
            }
            service.togglePlayPause()
        }
        service.handleMediaServicesReset()
        if !beforeReadiness {
            #expect(players.count == 1)
            #expect(!service.isPlaying)
            service.resumePlayback()
        }
        try await waitUntil("replacement player preserves exact original restoration") {
            players.count == 2 && service.isPlaying && players[1].currentTime().seconds >= savedPosition
        }
        service.togglePlayPause()
        #expect(players[1].currentTime().seconds < 90)
        #expect(service.currentTrackId == fixture.source.id)
        #expect(!service.isPlayingNarration)
    }

    @Test func variantsHaveIndependentPersistentResumeIncludingTheLastFiveSeconds() async throws {
        let fixture = try await NarrationPlaybackFixture()
        defer { fixture.remove() }
        let native = AVPlayer()
        let service = AudioPlayerService(
            settings: nil, connectsToSystem: false, narrationService: fixture.narrations,
            makePlayer: { native }
        )
        defer { service.stop() }
        fixture.narrations.savePosition(documentID: fixture.first.id, position: 7)
        fixture.narrations.savePosition(documentID: fixture.second.id, position: 56)
        service.playNarration(fixture.first, url: fixture.firstURL)
        try await waitUntil("first variant resumes") { service.isPlaying && native.currentTime().seconds >= 7 }
        #expect(native.currentTime().seconds < 10)
        service.seek(to: 13)
        service.playNarration(fixture.second, url: fixture.secondURL)
        #expect(fixture.narrations.position(for: fixture.first.id) == 13)
        try await waitUntil("second variant resumes near its end") {
            service.isPlaying && native.currentTime().seconds >= 56
        }
        service.togglePlayPause()
        #expect(native.currentTime().seconds < 59)
        #expect(service.isPlayingNarration)
        service.seek(to: 21)
        service.stop()

        let restored = NarrationService(directory: fixture.directory, defaults: fixture.defaults)
        await restored.load()
        #expect(restored.audioURL(for: fixture.first) != nil)
        #expect(restored.position(for: fixture.first.id) == 13)
        #expect(restored.position(for: fixture.second.id) == 21)
        service.playNarration(fixture.first, url: fixture.firstURL)
        try await waitUntil("first variant still resumes independently") {
            service.isPlaying && native.currentTime().seconds >= 13
        }
        #expect(native.currentTime().seconds < 16)
    }

    @Test func pauseSeekBackgroundAndStopCheckpointOnlyNarration() async throws {
        let fixture = try await NarrationPlaybackFixture()
        defer { fixture.remove() }
        let state = fixture.makePlaybackState()
        let native = AVPlayer()
        let service = AudioPlayerService(
            settings: nil, connectsToSystem: false, narrationService: fixture.narrations,
            makePlayer: { native }
        )
        defer { service.stop() }
        fixture.attach(state, to: service)
        state.recordPlay(discourseId: fixture.source.id)
        state.savePosition(discourseId: fixture.source.id, position: 39, duration: 90)
        let original = state.exportCloudSnapshot()
        service.playNarration(fixture.first, url: fixture.firstURL)
        try await waitUntil("narration starts") { service.isPlaying }
        service.seek(to: 12)
        #expect(fixture.narrations.position(for: fixture.first.id) == 12)
        try await waitUntil("seek reaches native player") { native.currentTime().seconds >= 12 }
        fixture.narrations.savePosition(documentID: fixture.first.id, position: 1)
        service.togglePlayPause()
        #expect(!service.isPlaying && service.isPlayingNarration)
        #expect(fixture.narrations.position(for: fixture.first.id) == service.currentTime)

        service.seek(to: 0)
        #expect(fixture.narrations.position(for: fixture.first.id) == 0)
        service.seek(to: 18)
        try await waitUntil("paused seek lands") { abs(native.currentTime().seconds - 18) < 0.05 }
        fixture.narrations.savePosition(documentID: fixture.first.id, position: 1)
        service.handleBackgroundEntry()
        #expect(fixture.narrations.position(for: fixture.first.id) == 18)
        service.seek(to: .nan)
        #expect(service.currentTime == 18)
        fixture.narrations.savePosition(documentID: fixture.first.id, position: 1)
        service.stop()
        #expect(fixture.narrations.position(for: fixture.first.id) == 18)
        #expect(service.currentNarration == nil)
        #expect(service.currentDiscourseID == nil)
        #expect(native.currentItem == nil)
        state.saveCurrentPosition()
        #expect(state.exportCloudSnapshot() == original)
    }

    @Test func tenSecondAutosaveRoutesNarrationWithoutCloudOrListeningStats() async throws {
        let fixture = try await NarrationPlaybackFixture()
        defer { fixture.remove() }
        var deltas: [TimeInterval] = []
        var statsSaves = 0
        var cloudSaves = 0
        let state = PlaybackStateService(
            defaults: fixture.defaults, recordListeningTime: { deltas.append($0) },
            saveListeningStats: { statsSaves += 1 }
        )
        state.onProgressSaved = { cloudSaves += 1 }
        let original = state.exportCloudSnapshot()
        let service = AudioPlayerService(settings: nil, connectsToSystem: false, narrationService: fixture.narrations)
        defer { service.stop() }
        fixture.attach(state, to: service)
        service.playNarration(fixture.first, url: fixture.firstURL)
        try await waitUntil("the real autosave task checkpoints narration", timeout: .seconds(25)) {
            fixture.narrations.position(for: fixture.first.id) >= 5
        }
        #expect(service.currentTime >= fixture.narrations.position(for: fixture.first.id))
        #expect(state.exportCloudSnapshot() == original)
        #expect(deltas.isEmpty)
        #expect(statsSaves == 0)
        #expect(cloudSaves == 0)
    }

    @Test(arguments: [true, false])
    func originalStatsCannotCatchUpAcrossNarrationEvenBetweenTicks(tickDuringNarration: Bool) async throws {
        let fixture = try await NarrationPlaybackFixture()
        defer { fixture.remove() }
        var deltas: [TimeInterval] = []
        let state = PlaybackStateService(
            defaults: fixture.defaults, recordListeningTime: { deltas.append($0) }, saveListeningStats: {}
        )
        let service = AudioPlayerService(settings: nil, connectsToSystem: false, narrationService: fixture.narrations)
        defer { service.stop() }
        fixture.attach(state, to: service)
        service.playQueue(items: [fixture.originalItem])
        service.isPlaying = true
        service.currentTime = 10
        state.saveCurrentPosition()
        service.currentTime = 20
        state.saveCurrentPosition()
        #expect(deltas == [10])

        service.playNarration(fixture.first, url: fixture.firstURL)
        if tickDuringNarration { state.saveCurrentPosition() }
        service.playQueue(items: [fixture.originalItem])
        service.isPlaying = true
        service.currentTime = 25
        state.saveCurrentPosition()
        #expect(deltas == [10])
        service.currentTime = 35
        state.saveCurrentPosition()
        #expect(deltas == [10, 10])
    }

    @Test(arguments: [true, false])
    func mediaResetPreservesNarrationURLMetadataAndPendingSeek(wasPlaying: Bool) async throws {
        let fixture = try await NarrationPlaybackFixture()
        defer { fixture.remove() }
        let state = fixture.makePlaybackState()
        var players: [AVPlayer] = []
        let service = AudioPlayerService(
            settings: nil, connectsToSystem: false, narrationService: fixture.narrations,
            makePlayer: {
                let player = AVPlayer()
                players.append(player)
                return player
            }
        )
        defer { service.stop() }
        fixture.attach(state, to: service)
        let original = state.exportCloudSnapshot()
        service.isNoiseReductionEnabled = true
        service.setVolume(4)
        service.setRate(1.5)
        service.playNarration(fixture.first, url: fixture.firstURL)
        try await waitUntil("first narration player starts") { service.isPlaying }
        let oldPlayer = try #require(players.first)
        let oldItem = try #require(oldPlayer.currentItem)
        let oldGeneration = service.playbackGeneration
        if !wasPlaying { service.togglePlayPause() }
        service.seek(to: 21)
        service.handleMediaServicesReset()
        #expect(fixture.narrations.position(for: fixture.first.id) == 21)
        #expect(service.currentNarration == fixture.first)
        #expect(service.queue.first?.url == fixture.firstURL)
        #expect(service.queue.first?.narration == fixture.first)
        let resumeTarget: TimeInterval
        if wasPlaying {
            resumeTarget = 21
        } else {
            #expect(players.count == 1)
            #expect(!service.isPlaying)
            service.seek(to: 25)
            #expect(fixture.narrations.position(for: fixture.first.id) == 25)
            service.resumePlayback()
            resumeTarget = 25
        }
        try await waitUntil("fresh native player restores narration") {
            players.count == 2 && service.isPlaying && players[1].currentTime().seconds >= resumeTarget
        }
        #expect(players[1] !== oldPlayer)
        #expect(players[1].currentTime().seconds < resumeTarget + 3)
        #expect(players[1].rate == 1.5)
        #expect((players[1].currentItem?.asset as? AVURLAsset)?.url == fixture.firstURL)
        #expect(players[1].currentItem?.audioMix == nil)
        #expect(!service.isBoostAvailable)
        try await assertSettledPlaybackRate(
            1.5, service: service, native: players[1], after: resumeTarget,
            phase: wasPlaying ? "narration playing reset" : "narration paused reset"
        )
        service.handleItemStatusChange(for: ObjectIdentifier(oldItem), generation: oldGeneration)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: oldItem)
        await Task.yield()
        #expect(service.currentNarration == fixture.first)
        #expect(service.currentDiscourseID == fixture.source.id)
        #expect(state.exportCloudSnapshot() == original)
    }

    @Test(arguments: [true, false])
    func preferredRateSurvivesOriginalPlaybackLifecycle(wasPlaying: Bool) async throws {
        let fixture = try await NarrationPlaybackFixture()
        defer { fixture.remove() }
        var players: [AVPlayer] = []
        let service = AudioPlayerService(
            settings: nil, connectsToSystem: false, narrationService: fixture.narrations,
            makePlayer: {
                let player = AVPlayer()
                players.append(player)
                return player
            }
        )
        defer { service.stop() }
        service.setRate(1.25)
        service.playQueue(items: [fixture.originalItem])
        let first = try #require(players.first)
        #expect(first.defaultRate == 1.25)
        #expect(first.automaticallyWaitsToMinimizeStalling)
        service.setRate(1.5)
        #expect(first.defaultRate == 1.5)
        #expect(first.rate == 0)
        try await waitUntil("original starts at the speed selected before readiness") {
            service.isPlaying && first.timeControlStatus == .playing && first.currentTime().seconds > 0.25
        }
        #expect(first.rate == 1.5)

        service.setRate(0.75)
        service.seek(to: 12)
        try await assertSettledPlaybackRate(0.75, service: service, native: first, after: 12, phase: "original live rate change")
        service.togglePlayPause()
        service.setRate(1.5)
        #expect(!service.isPlaying)
        #expect(first.rate == 0)
        #expect(first.defaultRate == 1.5)
        #expect((service.makeNowPlayingInfo()[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.floatValue == 0)
        #expect((service.makeNowPlayingInfo()[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? NSNumber)?.floatValue == 1.5)
        if wasPlaying { service.resumePlayback() }
        service.seek(to: 24)
        service.handleMediaServicesReset()
        if !wasPlaying {
            #expect(players.count == 1)
            #expect(!service.isPlaying)
            service.resumePlayback()
        }
        try await waitUntil("replacement original player restores its position") {
            players.count == 2 && service.isPlaying && players[1].currentTime().seconds >= 24
        }
        #expect(players[1] !== first)
        #expect(players[1].automaticallyWaitsToMinimizeStalling)
        try await assertSettledPlaybackRate(
            1.5, service: service, native: players[1], after: 24,
            phase: wasPlaying ? "original playing reset" : "original paused reset"
        )
        #expect(service.currentDiscourseID == fixture.source.id)
        #expect(!service.isPlayingNarration)
    }

    @Test func pendingResumeAndSeekSurviveResetAndStopBeforeReadiness() async throws {
        let fixture = try await NarrationPlaybackFixture()
        defer { fixture.remove() }
        var players: [AVPlayer] = []
        let service = AudioPlayerService(
            settings: nil, connectsToSystem: false, narrationService: fixture.narrations,
            makePlayer: {
                let player = AVPlayer()
                players.append(player)
                return player
            }
        )
        defer { service.stop() }
        fixture.narrations.savePosition(documentID: fixture.first.id, position: 12)
        service.playNarration(fixture.first, url: fixture.firstURL)
        service.handleBackgroundEntry()
        #expect(fixture.narrations.position(for: fixture.first.id) == 12)
        service.seek(to: 20)
        service.handleMediaServicesReset()
        service.stop()
        #expect(fixture.narrations.position(for: fixture.first.id) == 20)
        service.playNarration(fixture.first, url: fixture.firstURL)
        try await waitUntil("only the final player resumes the pending narration position") {
            service.isPlaying && (players.last?.currentTime().seconds ?? 0) >= 20
        }
        #expect((players.last?.currentTime().seconds ?? 0) < 23)
        #expect(service.currentNarration == fixture.first)
    }

    @Test func narrationHasNoDSPOrBoostAndOriginalRestoresSelectedProcessing() async throws {
        let fixture = try await NarrationPlaybackFixture()
        defer { fixture.remove() }
        let processor = NoiseReductionProcessor()
        let native = AVPlayer()
        var mixBuilds = 0
        let service = AudioPlayerService(
            settings: nil, connectsToSystem: false, narrationService: fixture.narrations,
            noiseProcessor: processor, makePlayer: { native },
            makeAudioMix: { processor, track, generation in
                mixBuilds += 1
                return processor.createAudioMix(for: track, generation: generation)
            }
        )
        defer { service.stop() }
        service.noiseReductionMode = .cadence
        service.isNoiseReductionEnabled = true
        service.setVolume(3)
        service.playQueue(items: [fixture.originalItem])
        try await waitUntil("original audio has a working tap") { service.audioProcessingStatus == .active }
        let oldItem = try #require(native.currentItem)
        #expect(mixBuilds == 1)
        #expect(service.isBoostAvailable)

        service.playNarration(fixture.first, url: fixture.firstURL)
        try await waitUntil("synthesized narration plays") { service.isPlaying }
        #expect(oldItem.audioMix == nil)
        #expect(native.currentItem?.audioMix == nil)
        #expect(processor.diagnosticsSnapshot().tapGeneration == nil)
        #expect(service.audioProcessingStatus == .synthesizedNarration)
        #expect(service.audioProcessingStatus.outcome == "narration_unprocessed")
        #expect(!service.audioProcessingStatus.isIssue)
        #expect(!service.isDeepFilterBypassing)
        #expect(!service.isAudioProcessingAttached)
        #expect(!service.isBoostAvailable)
        #expect(service.isNoiseReductionEnabled)
        #expect(service.volume == 3)
        #expect(native.volume == 1)

        service.isNoiseReductionEnabled = false
        service.isNoiseReductionEnabled = true
        service.noiseReductionMode = .rnnoise
        service.denoiseStrength = .strong
        service.voiceFocusPreset = .strong
        service.noiseReductionMode = .deepFilterNet
        service.setVolume(4)
        service.refreshAudioProcessingStatus()
        await Task.yield()
        #expect(mixBuilds == 1)
        #expect(native.currentItem?.audioMix == nil)
        #expect(processor.diagnosticsSnapshot().tapGeneration == nil)
        #expect(service.deepFilterStatus == .idle)
        #expect(!service.isBoostAvailable)
        #expect(service.noiseReductionAccessibilityValue.contains("apply to original recordings"))

        service.noiseReductionMode = .cadence
        service.stop()
        service.playQueue(items: [fixture.originalItem])
        try await waitUntil("original playback restores processing after narration stops") {
            mixBuilds == 2 && service.audioProcessingStatus == .active
        }
        #expect(service.isBoostAvailable)
        #expect(native.currentItem?.audioMix != nil)
        #expect(service.isNoiseReductionEnabled)
        #expect(service.noiseReductionMode == .cadence)
        #expect(service.denoiseStrength == .strong)
        #expect(service.voiceFocusPreset == .strong)
        #expect(service.volume == 4)
    }

    @Test(arguments: [true, false])
    func delayedOriginalMixCannotAttachToNarration(fails: Bool) async throws {
        let fixture = try await NarrationPlaybackFixture()
        defer { fixture.remove() }
        var pending: CheckedContinuation<Void, Error>?
        var loadFinished = false
        var mixBuilds = 0
        let native = AVPlayer()
        let service = AudioPlayerService(
            settings: nil, connectsToSystem: false, narrationService: fixture.narrations,
            makePlayer: { native },
            loadAudioTrack: { item in
                defer { loadFinished = true }
                let track = try await item.asset.loadTracks(withMediaType: .audio).first
                try await withCheckedThrowingContinuation { pending = $0 }
                return track
            },
            makeAudioMix: { _, _, _ in
                mixBuilds += 1
                return AVMutableAudioMix()
            }
        )
        defer {
            pending?.resume(throwing: CancellationError())
            service.stop()
        }
        service.isNoiseReductionEnabled = true
        service.playQueue(items: [fixture.originalItem])
        try await waitUntil("original track load is suspended") { pending != nil }
        service.playNarration(fixture.first, url: fixture.firstURL)
        try await waitUntil("narration starts independently of the original mix") { service.isPlaying }
        let continuation = try #require(pending)
        pending = nil
        if fails { continuation.resume(throwing: URLError(.cannotDecodeContentData)) }
        else { continuation.resume() }
        try await waitUntil("retired loader returns") { loadFinished }
        #expect(mixBuilds == 0)
        #expect(native.currentItem?.audioMix == nil)
        #expect(service.currentNarration == fixture.first)
        #expect(service.audioProcessingStatus == .synthesizedNarration)
        #expect(!service.isBoostAvailable)
    }

    @Test(arguments: [true, false], [true, false])
    func narrationEndSkipsOriginalCompletionAndAllSmartActions(natural: Bool, queuedOriginal: Bool) async throws {
        let fixture = try await NarrationPlaybackFixture()
        defer { fixture.remove() }
        let state = fixture.makePlaybackState()
        var downloads: [String] = []
        var deletions: [String] = []
        var fallbackLookups: [String] = []
        let native = AVPlayer()
        let service = AudioPlayerService(
            settings: nil, connectsToSystem: false, narrationService: fixture.narrations,
            originalPlaybackActions: .init(
                autoPlayNext: true, smartDownload: { downloads.append($0) },
                smartDelete: { deletions.append($0) },
                nextDownloadedItem: { fallbackLookups.append($0); return fixture.nextOriginalItem }
            ),
            makePlayer: { native }
        )
        defer { service.stop() }
        fixture.attach(state, to: service)
        state.recordPlay(discourseId: fixture.source.id)
        state.savePosition(discourseId: fixture.source.id, position: 35, duration: 90)
        let original = state.exportCloudSnapshot()
        let narration = AudioPlayerService.QueueItem(
            id: fixture.source.id, url: fixture.firstURL, title: fixture.source.displayTitle,
            series: fixture.source.seriesName, narration: fixture.first
        )
        service.playQueue(items: queuedOriginal ? [narration, fixture.nextOriginalItem] : [narration])
        try await waitUntil("narration begins") { service.isPlaying }
        #expect(service.currentTrackId == "narration:" + fixture.first.id)
        service.seek(to: 45)
        try await waitUntil("periodic observer crosses the preemptive download window") { service.currentTime > 45.1 }
        #expect(downloads.isEmpty)
        let item = try #require(native.currentItem)
        if natural {
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
        } else {
            service.skipForward(100)
        }
        try await waitUntil("narration finishes without advancing") { service.currentTrackId == nil }
        #expect(!service.isPlaying)
        #expect(service.currentNarration == nil)
        #expect(service.currentDiscourseID == nil)
        #expect(native.currentItem == nil)
        #expect(fixture.narrations.position(for: fixture.first.id) == 0)
        #expect(state.exportCloudSnapshot() == original)
        #expect(downloads.isEmpty)
        #expect(deletions.isEmpty)
        #expect(fallbackLookups.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.originalURL.path))
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
        await Task.yield()
        #expect(state.exportCloudSnapshot() == original)
        #expect(fixture.narrations.position(for: fixture.first.id) == 0)
    }

    @Test(arguments: [true, false])
    func originalCompletionStillRunsSmartActionsAndAutoAdvance(queuedNext: Bool) async throws {
        let fixture = try await NarrationPlaybackFixture()
        defer { fixture.remove() }
        let state = fixture.makePlaybackState()
        var downloads: [String] = []
        var deletions: [String] = []
        var lookups: [String] = []
        let native = AVPlayer()
        let service = AudioPlayerService(
            settings: nil, connectsToSystem: false, narrationService: fixture.narrations,
            originalPlaybackActions: .init(
                autoPlayNext: true, smartDownload: { downloads.append($0) },
                smartDelete: { deletions.append($0) },
                nextDownloadedItem: { lookups.append($0); return fixture.nextOriginalItem }
            ),
            makePlayer: { native }
        )
        defer { service.stop() }
        fixture.attach(state, to: service)
        service.playQueue(items: queuedNext ? [fixture.originalItem, fixture.nextOriginalItem] : [fixture.originalItem])
        try await waitUntil("original starts") { service.isPlaying }
        let item = try #require(native.currentItem)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
        try await waitUntil("next original starts") { service.currentTrackId == fixture.nextSource.id && service.isPlaying }
        #expect(state.isCompleted(fixture.source.id))
        #expect(state.listenedCompleted == [fixture.source.id])
        #expect(downloads == [fixture.source.id])
        #expect(deletions == [fixture.source.id])
        #expect(lookups == (queuedNext ? [] : [fixture.source.id]))
        #expect(!service.isPlayingNarration)
    }

    @Test(arguments: ["incomplete", "nonlocal", "missing", "wrong-file", "empty", "bad-segment", "unknown-source"])
    func invalidNarrationIsRejectedWithoutReplacingCurrentPlayback(kind: String) async throws {
        let fixture = try await NarrationPlaybackFixture()
        defer { fixture.remove() }
        let state = fixture.makePlaybackState()
        let native = AVPlayer()
        let service = AudioPlayerService(
            settings: nil, connectsToSystem: false, narrationService: fixture.narrations,
            makePlayer: { native }
        )
        defer { service.stop() }
        fixture.attach(state, to: service)
        service.playQueue(items: [fixture.originalItem, fixture.nextOriginalItem])
        try await waitUntil("original starts") { service.isPlaying }
        let item = try #require(native.currentItem)
        let generation = service.playbackGeneration
        let original = state.exportCloudSnapshot()
        var document = fixture.first
        var url = fixture.firstURL
        let failure: AudioPlayerService.NarrationPlaybackFailure
        switch kind {
        case "incomplete":
            document.segments = []
            failure = .incomplete
        case "nonlocal":
            url = try #require(URL(string: "https://example.invalid/narration.caf"))
            failure = .nonlocalAudio
        case "missing":
            try FileManager.default.removeItem(at: url)
            failure = .unavailableAudio
        case "wrong-file":
            url = fixture.originalURL
            failure = .unavailableAudio
        case "empty":
            try Data().write(to: url)
            failure = .unavailableAudio
        case "bad-segment":
            document.segments = [NarrationSegment(
                index: 1, sourceParagraphIndex: 0, text: "Test", audioFileName: "narration.caf", duration: 60
            )]
            failure = .incomplete
        default:
            document = NarrationDocument(
                id: document.id, discourseID: "missing-source", sourceDigest: document.sourceDigest,
                selection: document.selection, expectedSegmentCount: document.expectedSegmentCount,
                segments: document.segments, audioFileName: document.audioFileName,
                duration: document.duration, updatedAt: document.updatedAt
            )
            failure = .unknownDiscourse
        }
        service.playNarration(document, url: url)
        #expect(service.narrationPlaybackFailure == failure)
        #expect(native.currentItem === item)
        #expect(service.playbackGeneration == generation)
        #expect(service.currentNarration == nil)
        #expect(service.currentTrackId == fixture.source.id)
        #expect(service.queue.map(\.id) == [fixture.source.id, fixture.nextSource.id])
        #expect(state.exportCloudSnapshot() == original)
    }

    @Test func missingNarrationOnResumeKeepsItsIdentityAndNeverFallsBackToOriginal() async throws {
        let fixture = try await NarrationPlaybackFixture()
        defer { fixture.remove() }
        let state = fixture.makePlaybackState()
        let service = AudioPlayerService(settings: nil, connectsToSystem: false, narrationService: fixture.narrations)
        defer { service.stop() }
        fixture.attach(state, to: service)
        let original = state.exportCloudSnapshot()
        service.playNarration(fixture.first, url: fixture.firstURL)
        try await waitUntil("narration starts") { service.isPlaying }
        service.togglePlayPause()
        service.seek(to: 14)
        try FileManager.default.removeItem(at: fixture.firstURL)
        service.resumePlayback()
        #expect(!service.isPlaying)
        #expect(service.currentNarration == fixture.first)
        #expect(service.narrationPlaybackFailure == .unavailableAudio)
        service.handleMediaServicesReset()
        service.resumePlayback()
        #expect(!service.isPlaying)
        #expect(service.currentTrackId == "narration:" + fixture.first.id)
        #expect(service.narrationPlaybackFailure == .unavailableAudio)
        #expect(fixture.narrations.position(for: fixture.first.id) == 14)
        #expect(state.exportCloudSnapshot() == original)
    }

    @Test func corruptLocalNarrationFailsVisiblyWithoutOriginalProgress() async throws {
        let fixture = try await NarrationPlaybackFixture()
        defer { fixture.remove() }
        let state = fixture.makePlaybackState()
        let native = AVPlayer()
        let service = AudioPlayerService(
            settings: nil, connectsToSystem: false, narrationService: fixture.narrations, makePlayer: { native }
        )
        defer { service.stop() }
        fixture.attach(state, to: service)
        let original = state.exportCloudSnapshot()
        service.playNarration(fixture.first, url: fixture.firstURL)
        try await waitUntil("narration starts") { service.isPlaying }
        service.seek(to: 21)
        try Data("This is not an audio file.".utf8).write(to: fixture.originalURL)
        // A native item can fail after preflight; keep the registered cache valid for its retry.
        let failedItem = AVPlayerItem(url: fixture.originalURL)
        native.replaceCurrentItem(with: failedItem)
        try await waitUntil("the native replacement fails") { failedItem.status == .failed }
        service.handleItemStatusChange(for: ObjectIdentifier(failedItem), generation: service.playbackGeneration)
        #expect(service.narrationPlaybackFailure == .playback)
        #expect(!service.isPlaying)
        #expect(service.currentNarration == fixture.first)
        #expect(service.audioProcessingStatus == .setupFailed(.playback))
        #expect(!service.isAudioProcessingAttached)
        #expect(!service.isBoostAvailable)
        #expect(fixture.narrations.position(for: fixture.first.id) == 21)
        #expect(state.exportCloudSnapshot() == original)
        service.resumePlayback()
        try await waitUntil("retry reloads only the narration") {
            service.isPlaying && native.currentTime().seconds >= 21
        }
        #expect(service.narrationPlaybackFailure == nil)
        #expect(service.currentTrackId == AudioPlayerService.narrationTrackID(for: fixture.first.id))
        #expect((native.currentItem?.asset as? AVURLAsset)?.url == fixture.firstURL)
        #expect(state.exportCloudSnapshot() == original)
    }

    @Test func corruptLocalNarrationIsRejectedBeforeReplacingOriginal() async throws {
        let fixture = try await NarrationPlaybackFixture()
        defer { fixture.remove() }
        let state = fixture.makePlaybackState()
        let native = AVPlayer()
        let service = AudioPlayerService(
            settings: nil, connectsToSystem: false, narrationService: fixture.narrations, makePlayer: { native }
        )
        defer { service.stop() }
        fixture.attach(state, to: service)
        service.playQueue(items: [fixture.originalItem])
        try await waitUntil("original starts") { service.isPlaying }
        let originalItem = try #require(native.currentItem)
        let original = state.exportCloudSnapshot()
        try Data("This is not an audio file.".utf8).write(to: fixture.firstURL)
        service.playNarration(fixture.first, url: fixture.firstURL)
        #expect(service.narrationPlaybackFailure == .unavailableAudio)
        #expect(service.isPlaying)
        #expect(service.currentNarration == nil)
        #expect(native.currentItem === originalItem)
        #expect(state.exportCloudSnapshot() == original)
    }

    @Test func syntheticHistoryCannotReadOrWriteWatchSaveTimes() async throws {
        let fixture = try await NarrationPlaybackFixture()
        defer { fixture.remove() }
        let state = fixture.makePlaybackState()
        let id = AudioPlayerService.narrationTrackID(for: fixture.first.id)
        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        fixture.defaults.set(earlier.timeIntervalSince1970, forKey: "playbackSavedAt_" + id)
        #expect(state.lastSaved(discourseId: id) == nil)
        state.savePosition(discourseId: id, position: 24, duration: 60, savedAt: Date())
        state.clearPosition(discourseId: id)
        state.dismissFromRecent(discourseId: id)
        state.dismissListenedComplete(discourseId: id)
        state.unmarkCompleted(discourseId: id)
        #expect(fixture.defaults.double(forKey: "playbackSavedAt_" + id) == earlier.timeIntervalSince1970)
        #expect(state.getPosition(discourseId: id) == 0)
        #expect(state.completedCount(for: "narration:" + fixture.first.id) == 0)
        #expect(PlaybackStateService.mergeList(cloud: [id], local: [fixture.source.id, id], cap: 20) == [fixture.source.id])

        state.savePosition(discourseId: fixture.source.id, position: 24, duration: 90, savedAt: earlier)
        state.savePosition(discourseId: fixture.source.id, position: 24, duration: 90)
        #expect(state.lastSaved(discourseId: fixture.source.id) == earlier)
        let finished = earlier.addingTimeInterval(60)
        state.clearPosition(discourseId: fixture.source.id, at: finished)
        #expect(state.lastSaved(discourseId: fixture.source.id) == finished)
    }

    @Test func repeatedRemotePausePreservesNarrationSeekBeforeReadiness() async throws {
        let fixture = try await NarrationPlaybackFixture()
        defer { fixture.remove() }
        let state = fixture.makePlaybackState()
        let native = AVPlayer()
        let service = AudioPlayerService(
            settings: nil, connectsToSystem: false, narrationService: fixture.narrations, makePlayer: { native }
        )
        defer { service.stop() }
        fixture.attach(state, to: service)
        let original = state.exportCloudSnapshot()
        fixture.narrations.savePosition(documentID: fixture.first.id, position: 12)
        service.playNarration(fixture.first, url: fixture.firstURL)
        service.skipForward(10)
        service.skipBackward(2)
        #expect(service.currentTime == 20)
        service.setPlaying(false)
        service.setPlaying(false)
        #expect(fixture.narrations.position(for: fixture.first.id) == 20)
        try await waitUntil("paused narration finishes loading") { native.currentItem?.status == .readyToPlay }
        try await waitUntil("the pending narration seek lands without playing") {
            abs(native.currentTime().seconds - 20) < 0.05
        }
        #expect(!service.isPlaying)
        #expect(native.rate == 0)
        #expect(service.isPlayingNarration)
        #expect(service.playSession == nil)
        service.setPlaying(true)
        service.setPlaying(true)
        try await waitUntil("narration resumes") { service.isPlaying }
        #expect(service.playSession == nil)
        state.saveCurrentPosition()
        #expect(state.exportCloudSnapshot() == original)
        let trackID = try #require(service.currentTrackId)
        #expect(state.lastSaved(discourseId: trackID) == nil)
    }

    @Test func originalWatchCheckpointAndPlaySessionSurviveNarrationRoundTrip() async throws {
        let fixture = try await NarrationPlaybackFixture()
        defer { fixture.remove() }
        let state = fixture.makePlaybackState()
        let native = AVPlayer()
        let service = AudioPlayerService(
            settings: nil, connectsToSystem: false, narrationService: fixture.narrations, makePlayer: { native }
        )
        defer { service.stop() }
        fixture.attach(state, to: service)
        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        state.savePosition(discourseId: fixture.source.id, position: 8, duration: 90, savedAt: earlier)
        service.playQueue(items: [fixture.originalItem])
        try await waitUntil("original begins a Watch catch-up stretch") { service.isPlaying }
        #expect(service.playSession?.discourseID == fixture.source.id)
        #expect(service.playSession?.savedBefore == earlier)
        service.seek(to: 25)
        service.setPlaying(false)
        let checkpoint = try #require(state.lastSaved(discourseId: fixture.source.id))
        #expect(checkpoint > earlier)
        #expect(state.getPosition(discourseId: fixture.source.id) == 25)
        service.playNarration(fixture.first, url: fixture.firstURL)
        try await waitUntil("narration starts") { service.isPlaying }
        service.seek(to: 41)
        service.setPlaying(false)
        state.saveCurrentPosition()
        #expect(service.playSession == nil)
        #expect(state.lastSaved(discourseId: fixture.source.id) == checkpoint)
        #expect(state.getPosition(discourseId: fixture.source.id) == 25)
        service.returnToOriginal(
            localURL: fixture.originalURL, id: fixture.source.id,
            title: fixture.source.displayTitle, series: fixture.source.seriesName
        )
        try await waitUntil("original starts a fresh stretch") { service.isPlaying }
        let resumed = try #require(service.playSession)
        #expect(resumed.discourseID == fixture.source.id)
        #expect(resumed.savedBefore == checkpoint)
        #expect(abs(resumed.startPosition - 25) < 0.05)
    }

    @Test func cloudReconciliationNeverSeeksNarrationButStillMovesPausedOriginal() async throws {
        let fixture = try await NarrationPlaybackFixture()
        defer { fixture.remove() }
        let state = fixture.makePlaybackState()
        let native = AVPlayer()
        let service = AudioPlayerService(
            settings: nil, connectsToSystem: false, narrationService: fixture.narrations, makePlayer: { native }
        )
        defer { service.stop() }
        fixture.attach(state, to: service)
        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        state.savePosition(discourseId: fixture.source.id, position: 8, duration: 90, savedAt: earlier)
        service.playNarration(fixture.first, url: fixture.firstURL)
        service.seek(to: 20)
        service.setPlaying(false)
        let syntheticID = AudioPlayerService.narrationTrackID(for: fixture.first.id)
        let incoming = CloudSnapshot(
            positions: [fixture.source.id: 45, syntheticID: 55],
            durations: [fixture.source.id: 90, syntheticID: 60]
        )
        #expect(state.mergeCloudSnapshot(incoming))
        #expect(service.currentTime == 20)
        #expect(fixture.narrations.position(for: fixture.first.id) == 20)
        #expect(state.lastSaved(discourseId: fixture.source.id) == earlier)
        state.saveCurrentPosition()
        #expect(state.getPosition(discourseId: fixture.source.id) == 45)
        #expect(state.getPosition(discourseId: syntheticID) == 0)

        service.returnToOriginal(
            localURL: fixture.originalURL, id: fixture.source.id,
            title: fixture.source.displayTitle, series: fixture.source.seriesName
        )
        service.setPlaying(false)
        #expect(state.mergeCloudSnapshot(CloudSnapshot(positions: [fixture.source.id: 52])))
        #expect(service.currentTime == 52)
        try await waitUntil("paused original adopts the cloud seek while loading") {
            abs(native.currentTime().seconds - 52) < 0.05
        }
        #expect(!service.isPlaying)
        state.saveCurrentPosition()
        #expect(state.getPosition(discourseId: fixture.source.id) == 52)
        #expect(state.lastSaved(discourseId: fixture.source.id) == earlier)
    }

    @Test(arguments: ["stale-document", "other-rendition", "unregistered", "unknown-queued-source", "bare-synthetic"])
    func staleOrMismatchedNarrationCannotReplaceTheLoadedItem(kind: String) async throws {
        let fixture = try await NarrationPlaybackFixture()
        defer { fixture.remove() }
        let native = AVPlayer()
        let service = AudioPlayerService(
            settings: nil, connectsToSystem: false, narrationService: fixture.narrations, makePlayer: { native }
        )
        defer { service.stop() }
        service.playQueue(items: [fixture.originalItem])
        let original = try #require(native.currentItem)
        let generation = service.playbackGeneration
        var document = fixture.first
        var url = fixture.firstURL
        var failure: AudioPlayerService.NarrationPlaybackFailure = .unavailableAudio
        switch kind {
        case "stale-document": document.updatedAt = document.updatedAt.addingTimeInterval(1)
        case "other-rendition":
            #expect(fixture.firstURL.lastPathComponent == fixture.secondURL.lastPathComponent)
            url = fixture.secondURL
        case "unregistered":
            document = NarrationDocument(
                id: String(repeating: "a", count: 64), discourseID: document.discourseID,
                sourceDigest: document.sourceDigest, selection: document.selection,
                expectedSegmentCount: document.expectedSegmentCount, segments: document.segments,
                audioFileName: document.audioFileName, duration: document.duration, updatedAt: document.updatedAt
            )
        case "unknown-queued-source":
            document = NarrationDocument(
                id: document.id, discourseID: "missing-source", sourceDigest: document.sourceDigest,
                selection: document.selection, expectedSegmentCount: document.expectedSegmentCount,
                segments: document.segments, audioFileName: document.audioFileName,
                duration: document.duration, updatedAt: document.updatedAt
            )
            failure = .unknownDiscourse
        default: failure = .incomplete
        }
        let candidate = AudioPlayerService.QueueItem(
            id: AudioPlayerService.narrationTrackID(for: document.id), url: url,
            title: "Narration", series: "Test", narration: kind == "bare-synthetic" ? nil : document
        )
        service.playQueue(items: [candidate])
        #expect(service.narrationPlaybackFailure == failure)
        #expect(service.currentTrackId == fixture.source.id)
        #expect(service.currentNarration == nil)
        #expect(native.currentItem === original)
        #expect(service.playbackGeneration == generation)
    }

    #if canImport(WatchConnectivity) && !targetEnvironment(macCatalyst)
    @Test(arguments: [true, false])
    func watchOriginalReportCannotSeekOrUnloadNarration(playing: Bool) async throws {
        let fixture = try await NarrationPlaybackFixture()
        defer { fixture.remove() }
        let state = fixture.makePlaybackState()
        let service = AudioPlayerService(settings: nil, connectsToSystem: false, narrationService: fixture.narrations)
        defer { service.stop() }
        fixture.attach(state, to: service)
        service.playNarration(fixture.first, url: fixture.firstURL)
        try await waitUntil("narration starts") { service.isPlaying }
        service.seek(to: 20)
        service.setPlaying(playing)
        var moves: [TimeInterval] = []
        var unloads = 0
        let merger = WatchPositionMerger(
            playbackState: state, defaults: fixture.defaults,
            loaded: {
                service.currentTrackId.map {
                    .init(discourseID: $0, isPlaying: service.isPlaying)
                }
            },
            moveLoadedPlayer: { moves.append($0); service.seek(to: $0) },
            unloadLoadedPlayer: { unloads += 1; service.stop() }
        )
        // Whole Unix seconds survive the Date/UserDefaults representation change exactly.
        let reportTime = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let report = CompanionPositionReport(
            discourseID: fixture.source.id, position: 45, duration: 90, finished: false, recordedAt: reportTime
        )
        #expect(merger.apply(report) == .applied)
        #expect(state.getPosition(discourseId: fixture.source.id) == 45)
        #expect(state.lastSaved(discourseId: fixture.source.id) == reportTime)
        #expect(service.currentNarration == fixture.first)
        #expect(service.currentTime == 20)
        #expect(moves.isEmpty)
        let finish = CompanionPositionReport(
            discourseID: fixture.source.id, position: 90, duration: 90, finished: true,
            recordedAt: reportTime.addingTimeInterval(1)
        )
        #expect(merger.apply(finish) == .completed)
        #expect(unloads == 0)
        #expect(service.currentNarration == fixture.first)
        state.saveCurrentPosition()
        #expect(state.getPosition(discourseId: fixture.source.id) == 0)
        #expect(state.isCompleted(fixture.source.id))
        let synthetic = CompanionPositionReport(
            discourseID: AudioPlayerService.narrationTrackID(for: fixture.first.id),
            position: 20, duration: 60, finished: false, recordedAt: reportTime
        )
        #expect(merger.apply(synthetic) == .ignoredUnknownDiscourse)
        #expect(fixture.narrations.position(for: fixture.first.id) == 20)
    }
    #endif

    private func assertSettledPlaybackRate(
        _ expected: Float, service: AudioPlayerService, native: AVPlayer,
        after position: TimeInterval, phase: String
    ) async throws {
        try await waitUntil("native playback advances past its seek: \(phase)") {
            native.timeControlStatus == .playing && native.currentTime().seconds > position + 0.25
        }
        let startedAt = ProcessInfo.processInfo.systemUptime
        let startedTime = native.currentTime().seconds
        var rates: [Float] = []
        var continuous = true
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(200))
            rates.append(native.rate)
            continuous = continuous && native.timeControlStatus == .playing
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        let clockRate = (native.currentTime().seconds - startedTime) / elapsed
        print("Rate probe \(phase): default=\(native.defaultRate), samples=\(rates), native clock=\(clockRate), requested=\(expected)")
        #expect(continuous)
        #expect(rates.allSatisfy { $0 == expected })
        #expect(native.rate == expected)
        #expect(abs(clockRate - Double(expected)) < 0.15)
        #expect(service.playbackRate == expected)
        #expect((service.makeNowPlayingInfo()[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.floatValue == expected)
        #expect(native.defaultRate == expected)
        #expect((service.makeNowPlayingInfo()[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? NSNumber)?.floatValue == expected)
    }

    @Test func finishedPassagesPlayDuringPreparationWaitForMoreAndFinishOnce() async throws {
        let fixture = try await NarrationPlaybackFixture()
        defer { fixture.remove() }
        let clip = fixture.directory.appendingPathComponent("passage.m4a")
        try NarrationPlaybackFixture.writeAudio(to: clip, seconds: 1, compressed: true)
        let renderer = try GatedPlaybackNarrationRenderer(audioURL: clip, blockedCall: 3)
        let transcript = Transcript(
            discourseID: fixture.source.id, sourceID: "local-test", fetchedAt: Date(timeIntervalSince1970: 1),
            paragraphs: ["First passage.", "Second passage.", "Third passage."].enumerated().map {
                .init(index: $0.offset, text: $0.element, isEmphasis: false)
            }
        )
        let preparation = Task {
            try await fixture.narrations.prepare(
                transcript: transcript, selection: NarrationPlaybackFixture.selection(targetLanguage: "de", voice: "test-de"),
                translate: { $0 }, renderer: renderer
            )
        }
        defer { preparation.cancel() }
        await renderer.entered.wait()
        let partial = try #require(fixture.narrations.documents.first { $0.selection.targetLanguage == "de" })
        #expect(partial.segments.count == 2)

        let native = AVPlayer()
        let service = AudioPlayerService(
            settings: nil, connectsToSystem: false, narrationService: fixture.narrations, makePlayer: { native }
        )
        defer { service.stop() }
        let preview = NarrationPreviewPlayback(narrations: fixture.narrations)
        preview.play(documentID: partial.id, player: service)
        try await waitUntil("finished passages start") { service.isPlaying && service.isPlayingNarrationPreview }
        #expect(service.currentNarration?.segments.count == 2)
        #expect(abs(service.duration - partial.segments.reduce(0) { $0 + $1.duration }) < 0.1)
        #expect(service.currentTrackId == "narration:" + partial.id)

        // Reaching the last finished passage waits instead of ending the narration.
        try await waitUntil("playback catches up with preparation") { preview.waitingDocumentID == partial.id }
        #expect(!service.isPlaying)
        #expect(service.currentNarration?.id == partial.id)
        #expect(abs(fixture.narrations.position(for: partial.id) - service.duration) < 0.1)

        renderer.release.open()
        let complete = try await preparation.value
        try await waitUntil("playback continues with the new passage") {
            service.isPlaying && (service.currentNarration?.segments.count ?? 0) == 3 && service.currentTime >= 2
        }
        #expect(preview.waitingDocumentID == nil)
        try await waitUntil("the narration finishes once", timeout: .seconds(20)) { service.currentNarration == nil }
        #expect(fixture.narrations.position(for: complete.id) == 0)
        #expect(service.currentTrackId == nil)
    }

    @Test func aPartialTimelineCannotBeReusedForAnotherNarration() async throws {
        let fixture = try await NarrationPlaybackFixture()
        defer { fixture.remove() }
        let native = AVPlayer()
        let service = AudioPlayerService(
            settings: nil, connectsToSystem: false, narrationService: fixture.narrations, makePlayer: { native }
        )
        defer { service.stop() }
        var unfinished = fixture.first
        unfinished.audioFileName = nil
        service.playNarration(unfinished, url: fixture.firstURL)
        #expect(service.narrationPlaybackFailure == .incomplete)
        #expect(service.currentNarration == nil)
    }

    @Test func caughtUpPlaybackContinuesAfterPreparationIsPausedAndResumed() async throws {
        let fixture = try await NarrationPlaybackFixture()
        defer { fixture.remove() }
        let clip = fixture.directory.appendingPathComponent("passage.m4a")
        try NarrationPlaybackFixture.writeAudio(to: clip, seconds: 1, compressed: true)
        let transcript = Transcript(
            discourseID: fixture.source.id, sourceID: "local-test", fetchedAt: Date(timeIntervalSince1970: 1),
            paragraphs: ["First passage.", "Second passage.", "Third passage."].enumerated().map {
                .init(index: $0.offset, text: $0.element, isEmphasis: false)
            }
        )
        let choice = NarrationPlaybackFixture.selection(targetLanguage: "de", voice: "test-de")
        let paused = try GatedPlaybackNarrationRenderer(audioURL: clip, blockedCall: 2)
        let first = Task {
            try await fixture.narrations.prepare(transcript: transcript, selection: choice, translate: { $0 }, renderer: paused)
        }
        await paused.entered.wait()
        let partial = try #require(fixture.narrations.documents.first { $0.selection.targetLanguage == "de" })
        let native = AVPlayer()
        let service = AudioPlayerService(
            settings: nil, connectsToSystem: false, narrationService: fixture.narrations, makePlayer: { native }
        )
        defer { service.stop() }
        let preview = NarrationPreviewPlayback(narrations: fixture.narrations)
        preview.play(documentID: partial.id, player: service)
        try await waitUntil("caught up") { preview.waitingDocumentID == partial.id }

        fixture.narrations.cancel()
        paused.release.open()
        _ = try? await first.value
        #expect(preview.waitingDocumentID == nil)
        #expect(service.currentNarration?.id == partial.id)

        let resumed = try GatedPlaybackNarrationRenderer(audioURL: clip, blockedCall: 0)
        _ = try await fixture.narrations.prepare(transcript: transcript, selection: choice, translate: { $0 }, renderer: resumed)
        try await waitUntil("playback continues after the pause, not from the start") {
            service.isPlaying && (service.currentNarration?.segments.count ?? 0) >= 2 && service.currentTime >= 1
        }
    }

    private func waitUntil(
        _ message: String, timeout: Duration = .seconds(15), _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(condition(), "Timed out: \(message)")
    }
}

@MainActor
private final class GatedPlaybackNarrationRenderer: NarrationSpeechRendering {
    let entered = PlaybackTestGate()
    let release = PlaybackTestGate()
    private let audioURL: URL
    private let duration: TimeInterval
    private let blockedCall: Int
    private var calls = 0

    init(audioURL: URL, blockedCall: Int) throws {
        self.audioURL = audioURL
        self.blockedCall = blockedCall
        let file = try AVAudioFile(forReading: audioURL)
        duration = Double(file.length) / file.processingFormat.sampleRate
    }

    func render(text: String, voiceID: String, to outputURL: URL) async throws -> TimeInterval {
        calls += 1
        if calls == blockedCall {
            entered.open()
            await release.wait()
        }
        try FileManager.default.copyItem(at: audioURL, to: outputURL)
        return duration
    }

    func assemble(segments: [URL], to outputURL: URL) async throws -> TimeInterval {
        let timeline = try await NarrationPreviewPlayback.timeline(joining: segments)
        guard let export = AVAssetExportSession(asset: timeline, presetName: AVAssetExportPresetAppleM4A) else {
            throw NativeNarrationSpeechError.exportUnavailable
        }
        try await export.export(to: outputURL, as: .m4a)
        let file = try AVAudioFile(forReading: outputURL)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    func cancel() {}
}

@MainActor
private final class PlaybackTestGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
private struct NarrationPlaybackFixture {
    let directory: URL
    let defaults: UserDefaults
    let suite: String
    let originalURL: URL
    let firstURL: URL
    let secondURL: URL
    let source: CatalogDiscourse
    let nextSource: CatalogDiscourse
    let first: NarrationDocument
    let second: NarrationDocument
    let narrations: NarrationService

    init() async throws {
        suite = "NarrationPlayback-" + UUID().uuidString
        defaults = try #require(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        originalURL = directory.appendingPathComponent("original.caf")
        let discourses = Catalog.discourses(for: try #require(Catalog.englishSeries.first))
        source = try #require(discourses.first)
        nextSource = try #require(discourses.dropFirst().first)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try Self.writeAudio(to: originalURL, seconds: 90)
            let seed = directory.appendingPathComponent("generated.m4a")
            try Self.writeAudio(to: seed, seconds: 60, compressed: true)
            let store = NarrationService(directory: directory, defaults: defaults)
            let transcript = Transcript(
                discourseID: source.id, sourceID: "local-test", fetchedAt: Date(timeIntervalSince1970: 1),
                paragraphs: [.init(index: 0, text: "A prepared local narration.", isEmphasis: false)]
            )
            let renderer = try LocalPlaybackNarrationRenderer(audioURL: seed)
            first = try await store.prepare(
                transcript: transcript, selection: Self.selection(targetLanguage: "es", voice: "test-es"),
                translate: { $0 }, renderer: renderer
            )
            second = try await store.prepare(
                transcript: transcript, selection: Self.selection(targetLanguage: "fr", voice: "test-fr"),
                translate: { $0 }, renderer: renderer
            )
            firstURL = try #require(store.audioURL(for: first))
            secondURL = try #require(store.audioURL(for: second))
            narrations = store
        } catch {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    var originalItem: AudioPlayerService.QueueItem {
        .init(id: source.id, url: originalURL, title: source.displayTitle, series: source.seriesName)
    }

    var nextOriginalItem: AudioPlayerService.QueueItem {
        .init(id: nextSource.id, url: originalURL, title: nextSource.displayTitle, series: nextSource.seriesName)
    }

    func makePlaybackState() -> PlaybackStateService {
        PlaybackStateService(defaults: defaults, recordListeningTime: { _ in }, saveListeningStats: {})
    }

    func attach(_ state: PlaybackStateService, to service: AudioPlayerService) {
        service.playbackStateService = state
        state.attach(to: service)
    }

    func remove() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    fileprivate static func selection(targetLanguage: String, voice: String) -> NarrationSelection {
        NarrationSelection(
            sourceLanguage: "en", targetLanguage: targetLanguage,
            voice: NarrationVoice(id: voice, name: "Local test voice", language: targetLanguage, quality: 1)
        )
    }

    fileprivate static func writeAudio(to url: URL, seconds: TimeInterval, compressed: Bool = false) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1))
        let settings: [String: Any] = compressed ? [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
        ] : format.settings
        let file = try AVAudioFile(forWriting: url, settings: settings)
        defer { file.close() }
        let block = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        let samples = try #require(block.floatChannelData)[0]
        let frames = Int(seconds * format.sampleRate)
        var offset = 0
        while offset < frames {
            let count = min(4096, frames - offset)
            block.frameLength = AVAudioFrameCount(count)
            for index in 0..<count {
                let time = Double(offset + index) / format.sampleRate
                samples[index] = Float(0.02 * sin(2 * .pi * 170 * time))
            }
            try file.write(from: block)
            offset += count
        }
    }
}

@MainActor
private final class LocalPlaybackNarrationRenderer: NarrationSpeechRendering {
    private let audioURL: URL
    private let duration: TimeInterval

    init(audioURL: URL) throws {
        self.audioURL = audioURL
        let file = try AVAudioFile(forReading: audioURL)
        duration = Double(file.length) / file.processingFormat.sampleRate
    }

    func render(text: String, voiceID: String, to outputURL: URL) async throws -> TimeInterval {
        try FileManager.default.copyItem(at: audioURL, to: outputURL)
        return duration
    }

    func assemble(segments: [URL], to outputURL: URL) async throws -> TimeInterval {
        #expect(segments.count == 1)
        try FileManager.default.copyItem(at: try #require(segments.first), to: outputURL)
        return duration
    }

    func cancel() {}
}
