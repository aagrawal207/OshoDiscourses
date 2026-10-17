import AVFoundation
import Foundation
import Testing
import UIKit
@testable import OshoDiscourses

/// Cold-launch restore: which talk returns, and that it comes back paused
/// without claiming the audio session until the listener presses play.
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct SessionRestoreTests {
    @MainActor
    private final class Counter {
        var value = 0
    }

    private struct Harness {
        let state: PlaybackStateService
        let service: AudioPlayerService
        let nativePlayer: AVPlayer
        let activations: Counter
        let mixBuilds: Counter
        let suite: String

        @MainActor func tearDown() {
            service.stop()
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
    }

    private func makeState() throws -> (PlaybackStateService, String) {
        let suite = "session-restore-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (PlaybackStateService(defaults: defaults, recordListeningTime: { _ in }, saveListeningStats: {}), suite)
    }

    private func makeHarness() throws -> Harness {
        let (state, suite) = try makeState()
        let nativePlayer = AVPlayer()
        let activations = Counter()
        let mixBuilds = Counter()
        let service = AudioPlayerService(
            settings: nil, connectsToSystem: false,
            makePlayer: { nativePlayer },
            makeAudioMix: { processor, track, generation in
                mixBuilds.value += 1
                return processor.createAudioMix(for: track, generation: generation)
            },
            activateAudioSession: { activations.value += 1 }
        )
        service.playbackStateService = state
        return Harness(
            state: state, service: service, nativePlayer: nativePlayer,
            activations: activations, mixBuilds: mixBuilds, suite: suite
        )
    }

    private func item(_ audio: PlaybackAudioFixture, id: String = "talk") -> AudioPlayerService.QueueItem {
        .init(id: id, url: audio.url, title: "Talk", series: "Integration")
    }

    // MARK: Selection

    /// Real catalog ids, since Continue Listening drops ids the catalog lacks.
    private func catalogIDs(_ count: Int) -> [String] {
        Array(Catalog.allDiscourses().prefix(count).map(\.id))
    }

    /// A store with no saved translations, isolated from the host app's.
    private func emptyNarrations() throws -> (NarrationService, String) {
        let suite = "session-restore-narrations-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        return (NarrationService(directory: directory, defaults: defaults), suite)
    }

    /// The track relaunch restore tries first, through the selection Home uses.
    private func restoreTarget(
        _ state: PlaybackStateService, isDownloaded: (String) -> Bool, hasFile: (String) -> Bool
    ) throws -> String? {
        let (narrations, suite) = try emptyNarrations()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let rows = ContinueListening.rows(
            playbackState: state, narrations: narrations, isDownloaded: isDownloaded, currentTrackID: nil
        )
        return ContinueListening.restoreCandidates(rows, hasFile: hasFile, hasNarrationAudio: { _ in true }).first?.trackID
    }

    @Test func restoresTheFirstContinueListeningRow() throws {
        let (state, suite) = try makeState()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let ids = catalogIDs(5)
        let (older, chosen, unstarted, missingFile, deleted) = (ids[0], ids[1], ids[2], ids[3], ids[4])
        for id in [older, chosen, missingFile, deleted] { state.savePosition(discourseId: id, position: 30, duration: 600) }
        for id in [older, chosen, unstarted, missingFile, deleted, "not-in-catalog"] { state.recordPlay(discourseId: id) }
        state.savePosition(discourseId: "not-in-catalog", position: 30, duration: 600)
        let downloaded: Set = [older, chosen, unstarted, missingFile, "not-in-catalog"]

        let rows = state.continueListeningIDs(isDownloaded: downloaded.contains, currentTrackID: nil)
        #expect(rows == [missingFile, chosen, older])
        // A manifest entry whose file is gone is dropped, as Home drops it once evicted.
        let restored = try restoreTarget(state, isDownloaded: downloaded.contains, hasFile: { $0 != missingFile })
        #expect(restored == chosen)
        #expect(try restoreTarget(state, isDownloaded: downloaded.contains, hasFile: { _ in true }) == rows.first)
    }

    @Test func aCompletedTalkBeingHeardAgainIsRestored() throws {
        let (state, suite) = try makeState()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let ids = catalogIDs(2)
        state.savePosition(discourseId: ids[0], position: 50, duration: 600)
        state.recordPlay(discourseId: ids[0])
        // Finished once, then started again from the series page.
        state.markListenedComplete(discourseId: ids[1])
        state.recordPlay(discourseId: ids[1])
        state.savePosition(discourseId: ids[1], position: 40, duration: 600)
        #expect(state.isCompleted(ids[1]))

        #expect(state.continueListeningIDs(isDownloaded: { _ in true }, currentTrackID: nil).first == ids[1])
        #expect(try restoreTarget(state, isDownloaded: { _ in true }, hasFile: { _ in true }) == ids[1])
    }

    @Test func nothingIsRestoredWhenContinueListeningIsEmpty() throws {
        let (state, suite) = try makeState()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let ids = catalogIDs(3)
        #expect(try restoreTarget(state, isDownloaded: { _ in true }, hasFile: { _ in true }) == nil, "no saved state")

        state.savePosition(discourseId: ids[0], position: 590, duration: 600)
        state.recordPlay(discourseId: ids[0])
        // A natural finish, as the player records it.
        state.markListenedComplete(discourseId: ids[0])
        state.clearPosition(discourseId: ids[0])
        state.recordPlay(discourseId: ids[1])
        state.savePosition(discourseId: ids[2], position: 30, duration: 600)
        state.recordPlay(discourseId: ids[2])

        let downloaded: Set = [ids[0], ids[1]]
        #expect(state.continueListeningIDs(isDownloaded: downloaded.contains, currentTrackID: nil).isEmpty)
        #expect(try restoreTarget(state, isDownloaded: downloaded.contains, hasFile: { _ in true }) == nil)
        // The loaded talk is listed without a saved position; a cold launch has none loaded.
        #expect(state.continueListeningIDs(isDownloaded: downloaded.contains, currentTrackID: ids[1]) == [ids[1]])
    }

    @Test func homeAndCompanionsListTheSameContinueListeningRows() throws {
        let (state, suite) = try makeState()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let downloads = DownloadService()
        let player = AudioPlayerService(settings: nil, connectsToSystem: false)
        defer { player.stop() }
        let library = CompanionLibrary(downloads: downloads, playbackState: state, bookmarks: .shared, player: player)
        let onDisk = Catalog.allDiscourses().filter { downloads.isDownloaded($0.id) }.prefix(3).map(\.id)
        let gone = try #require(Catalog.allDiscourses().first { !downloads.isDownloaded($0.id) }).id
        for id in onDisk + [gone] {
            state.savePosition(discourseId: id, position: 30, duration: 600)
            state.recordPlay(discourseId: id)
        }

        let rows = state.continueListeningIDs(isDownloaded: downloads.isDownloaded, currentTrackID: nil)
        #expect(rows == Array(onDisk.reversed()))
        #expect(library.continueListening().map(\.id) == rows.map(CompanionLibrary.rowID(discourse:)))
    }

    @Test func launcherSkipsATalkWhoseDownloadIsGone() async throws {
        let (state, suite) = try makeState()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let (narrations, narrationSuite) = try emptyNarrations()
        defer { UserDefaults(suiteName: narrationSuite)?.removePersistentDomain(forName: narrationSuite) }
        let player = AudioPlayerService(settings: nil, connectsToSystem: false, narrationService: narrations)
        defer { player.stop() }
        let downloads = DownloadService()
        let launcher = PlaybackLauncher(
            player: player, downloads: downloads, bookmarks: .shared,
            narrations: narrations, narrationPlayback: NarrationPreviewPlayback(narrations: narrations)
        )
        let gone = try #require(Catalog.allDiscourses().first { !downloads.isDownloaded($0.id) })
        state.savePosition(discourseId: gone.id, position: 120, duration: 3600)
        state.recordPlay(discourseId: gone.id)

        #expect(await launcher.restoreLastSession(from: state) == nil)
        #expect(player.currentTrackId == nil)
    }

    // MARK: Paused state

    @Test func restoredTalkWaitsPausedAtItsSavedPositionWithoutClaimingTheSession() async throws {
        let audio = try PlaybackAudioFixture(seconds: 60)
        defer { audio.remove() }
        let harness = try makeHarness()
        defer { harness.tearDown() }
        let service = harness.service
        harness.state.savePosition(discourseId: "talk", position: 20, duration: 60)

        service.restoreQueue(items: [item(audio)])
        #expect(service.currentTrackId == "talk")
        #expect(service.currentTime == 20, "the mini-player shows the saved position at once")
        #expect(service.duration == 60)
        #expect(!service.isPlaying)

        try await waitUntil("the item is ready at the saved position") {
            harness.nativePlayer.currentItem?.status == .readyToPlay
                && abs(harness.nativePlayer.currentTime().seconds - 20) < 0.5
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!service.isPlaying)
        #expect(harness.nativePlayer.rate == 0)
        #expect(harness.nativePlayer.timeControlStatus == .paused)
        #expect(abs(service.currentTime - 20) < 0.5)

        // Launch makes the scene active; that must not take audio from another app.
        service.handleForegroundReturn()
        #expect(harness.activations.value == 0)
        #expect(!service.hasClaimedAudioSession)
        #expect(service.playSession == nil)

        harness.state.saveCurrentPosition()
        #expect(abs(harness.state.getPosition(discourseId: "talk") - 20) < 0.5)
    }

    @Test func firstPlayResumesFromTheSavedPositionAndClaimsTheSession() async throws {
        let audio = try PlaybackAudioFixture(seconds: 60)
        defer { audio.remove() }
        let harness = try makeHarness()
        defer { harness.tearDown() }
        let service = harness.service
        harness.state.savePosition(discourseId: "talk", position: 20, duration: 60)
        harness.state.recordPlay(discourseId: "talk")
        harness.state.recordPlay(discourseId: "elsewhere")

        service.restoreQueue(items: [item(audio)])
        try await waitUntil("the item is ready") { harness.nativePlayer.currentItem?.status == .readyToPlay }
        #expect(harness.activations.value == 0)

        service.togglePlayPause()
        try await waitUntil("playback starts") {
            service.isPlaying && harness.nativePlayer.timeControlStatus == .playing
        }
        #expect(harness.activations.value == 1)
        #expect(service.hasClaimedAudioSession)
        let session = try #require(service.playSession)
        #expect(abs(session.startPosition - 20) < 0.5)
        let clock = harness.nativePlayer.currentTime().seconds
        #expect(clock >= 19.5 && clock < 23)
        #expect(harness.state.recentlyPlayed.first == "talk")

        // Claimed for the process: foreground return reclaims it like any played talk.
        service.handleForegroundReturn()
        #expect(harness.activations.value == 2)
    }

    @Test func playBeforeTheItemIsReadyStillStartsAtTheSavedPosition() async throws {
        let audio = try PlaybackAudioFixture(seconds: 60)
        defer { audio.remove() }
        let harness = try makeHarness()
        defer { harness.tearDown() }
        let service = harness.service
        harness.state.savePosition(discourseId: "talk", position: 20, duration: 60)

        service.restoreQueue(items: [item(audio)])
        service.setPlaying(true)
        try await waitUntil("playback starts") { service.isPlaying }
        let session = try #require(service.playSession)
        #expect(abs(session.startPosition - 20) < 0.5)
        #expect(harness.activations.value == 1)
    }

    @Test func restoredTalkSeeksSkipsAndChangesSpeedWhilePaused() async throws {
        let audio = try PlaybackAudioFixture(seconds: 60)
        defer { audio.remove() }
        let harness = try makeHarness()
        defer { harness.tearDown() }
        let service = harness.service
        harness.state.savePosition(discourseId: "talk", position: 20, duration: 60)

        service.restoreQueue(items: [item(audio)])
        // A skip while loading acts from the position on screen, not the item's 0.
        service.skipForward(10)
        #expect(service.currentTime == 30)
        try await waitUntil("the item is ready at the skipped position") {
            harness.nativePlayer.currentItem?.status == .readyToPlay
                && abs(harness.nativePlayer.currentTime().seconds - 30) < 0.5
        }

        service.skipBackward(15)
        try await waitUntil("the backward skip lands") { abs(harness.nativePlayer.currentTime().seconds - 15) < 0.5 }
        service.setRate(1.5)
        #expect(service.playbackRate == 1.5)
        #expect(harness.nativePlayer.defaultRate == 1.5)
        #expect(!service.isPlaying)
        #expect(harness.nativePlayer.rate == 0)
        #expect(harness.activations.value == 0)

        service.setPlaying(true)
        try await waitUntil("playback starts at the new speed") {
            service.isPlaying && harness.nativePlayer.rate == 1.5
        }
        let session = try #require(service.playSession)
        #expect(abs(session.startPosition - 15) < 0.5)
    }

    @Test func deNoiseTapIsCreatedOnFirstPlay() async throws {
        let audio = try PlaybackAudioFixture(seconds: 60)
        defer { audio.remove() }
        let harness = try makeHarness()
        defer { harness.tearDown() }
        let service = harness.service
        service.noiseReductionMode = .rnnoise
        service.isNoiseReductionEnabled = true
        harness.state.savePosition(discourseId: "talk", position: 20, duration: 60)

        service.restoreQueue(items: [item(audio)])
        try await waitUntil("the item is ready") { harness.nativePlayer.currentItem?.status == .readyToPlay }
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.mixBuilds.value == 0)
        #expect(harness.nativePlayer.currentItem?.audioMix == nil)
        #expect(service.audioProcessingStatus == .waitingForPlayback)

        service.setPlaying(true)
        try await waitUntil("the tap attaches and processes", timeout: .seconds(30)) {
            harness.mixBuilds.value == 1
                && harness.nativePlayer.currentItem?.audioMix != nil
                && service.audioProcessingStatus == .active
        }
    }

    @Test func restoreLeavesAnAlreadyLoadedTalkAlone() async throws {
        let audio = try PlaybackAudioFixture(seconds: 30)
        defer { audio.remove() }
        let harness = try makeHarness()
        defer { harness.tearDown() }
        let service = harness.service
        service.play(localURL: audio.url, id: "chosen", title: "Chosen", series: "Integration")
        service.restoreQueue(items: [item(audio, id: "restored")])
        #expect(service.currentTrackId == "chosen")
        try await waitUntil("the chosen talk plays") { service.isPlaying }
    }

    @Test func companionsSeeTheRestoredTalkAsPaused() async throws {
        let audio = try PlaybackAudioFixture(seconds: 60)
        defer { audio.remove() }
        let harness = try makeHarness()
        defer { harness.tearDown() }
        harness.state.savePosition(discourseId: "talk", position: 20, duration: 60)
        harness.service.restoreQueue(items: [item(audio)])
        let library = CompanionLibrary(
            downloads: DownloadService(), playbackState: harness.state, bookmarks: .shared, player: harness.service
        )

        let nowPlaying = try #require(library.nowPlaying())
        #expect(nowPlaying.discourseID == "talk")
        #expect(!nowPlaying.isPlaying)
        #expect(nowPlaying.elapsed == 20)
        #expect(nowPlaying.duration == 60)
    }

    // MARK: Background save

    @Test func leavingTheForegroundSavesThePositionOnce() throws {
        let (state, suite) = try makeState()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let player = AudioPlayerService(settings: nil, connectsToSystem: false)
        defer { player.stop() }
        state.attach(to: player)
        let center = NotificationCenter()
        state.saveWhenLeavingForeground(center: center)
        state.saveWhenLeavingForeground(center: center)
        let pushes = Counter()
        state.onProgressSaved = { pushes.value += 1 }
        state.savePosition(discourseId: "talk", position: 110, duration: 600, savedAt: Date(timeIntervalSince1970: 1_700_000_000))
        player.currentTrackId = "talk"
        player.duration = 600
        player.currentTime = 119.6

        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(state.getPosition(discourseId: "talk") == 119.6)
        #expect(pushes.value == 1, "registered once, so one save per notification")
        let savedAt = try #require(state.lastSaved(discourseId: "talk"))
        #expect(savedAt > Date(timeIntervalSince1970: 1_700_000_000))

        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(state.getPosition(discourseId: "talk") == 119.6)
        #expect(state.lastSaved(discourseId: "talk") == savedAt, "an unmoved position keeps its save time")

        player.currentTime = 121.2
        center.post(name: UIApplication.willTerminateNotification, object: nil)
        #expect(state.getPosition(discourseId: "talk") == 121.2)
        player.currentTime = 125.4
        center.post(name: UIApplication.willResignActiveNotification, object: nil)
        #expect(state.getPosition(discourseId: "talk") == 125.4)
    }

    @Test func leavingTheForegroundSavesThePlayingTalksLiveClock() async throws {
        let audio = try PlaybackAudioFixture(seconds: 30)
        defer { audio.remove() }
        let harness = try makeHarness()
        defer { harness.tearDown() }
        harness.state.attach(to: harness.service)
        let center = NotificationCenter()
        harness.state.saveWhenLeavingForeground(center: center)
        harness.service.play(localURL: audio.url, id: "talk", title: "Talk", series: "Integration")
        try await waitUntil("playing past 2 s") {
            harness.service.isPlaying && harness.nativePlayer.currentTime().seconds > 2.2
        }

        center.post(name: UIApplication.willResignActiveNotification, object: nil)
        let live = harness.nativePlayer.currentTime().seconds
        #expect(abs(harness.state.getPosition(discourseId: "talk") - live) < 0.1)
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
