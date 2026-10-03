#if canImport(WatchConnectivity) && !targetEnvironment(macCatalyst)
import Foundation
import Testing
@testable import OshoDiscourses

@MainActor
@Suite struct WatchTransferTests {
    let transport = FakeWatchTransport()
    let library = FakeTransferLibrary()
    let defaults = WatchFixture.defaults()
    let staging = WatchFixture.tempDirectory()
    let id = WatchFixture.ids[0]

    private func service() -> WatchTransferService {
        WatchTransferService(sink: transport, library: library, defaults: defaults, stagingDirectory: staging)
    }

    private func seedDownload(_ id: String) throws {
        let url = WatchFixture.tempDirectory().appendingPathComponent("talk.mp3")
        try Data(repeating: 7, count: 2048).write(to: url)
        library.files[id] = url
    }

    @Test func queuesAStagedCopyWithResumeMetadata() throws {
        try seedDownload(id)
        library.positions[id] = 321
        library.durations[id] = 4000
        let transfers = service()
        #expect(try transfers.send(id) == .queued)
        let sent = try #require(transport.transfers.first)
        #expect(sent.file.discourseID == id)
        #expect(sent.file.resumePosition == 321)
        #expect(sent.file.duration == 4000)
        #expect(sent.file.title == Catalog.discourseLookup[id]?.discourse.displayTitle)
        #expect(sent.url.deletingLastPathComponent().standardizedFileURL == staging.standardizedFileURL)
        #expect(FileManager.default.contentsEqual(atPath: sent.url.path, andPath: library.files[id]!.path))
        #expect(transfers.sending == [id])
    }

    @Test func outstandingOrOnWatchDiscoursesAreNotSentAgain() throws {
        try seedDownload(id)
        let transfers = service()
        #expect(try transfers.send(id) == .queued)
        #expect(try transfers.send(id) == .alreadySending)
        // A transfer from an earlier launch, known only to the session.
        let other = WatchFixture.ids[1]
        try seedDownload(other)
        transport.outstanding.insert(other)
        #expect(try transfers.send(other) == .alreadySending)
        let third = WatchFixture.ids[2]
        try seedDownload(third)
        transfers.updateInventory([third])
        #expect(try transfers.send(third) == .alreadyOnWatch)
        #expect(transport.transfers.count == 1)
    }

    @Test func failuresExplainWhatToDo() throws {
        let transfers = service()
        #expect(throws: WatchTransferService.Failure.notDownloaded) { try transfers.send(id) }
        #expect(transfers.failures[id] == WatchTransferService.Failure.notDownloaded.message)
        #expect(throws: WatchTransferService.Failure.unknownDiscourse) { try transfers.send("no-such-talk") }

        try seedDownload(id)
        transport.linkState = .ready(paired: false, installed: false, reachable: false)
        #expect(throws: WatchTransferService.Failure.notPaired) { try transfers.send(id) }
        transport.linkState = .ready(paired: true, installed: false, reachable: false)
        #expect(throws: WatchTransferService.Failure.watchAppNotInstalled) { try transfers.send(id) }
        transport.linkState = .inactive
        #expect(throws: WatchTransferService.Failure.unavailable) { try transfers.send(id) }
        transport.linkState = .ready(paired: true, installed: true, reachable: false)
        transport.failsTransfer = true
        #expect(throws: WatchTransferService.Failure.unavailable) { try transfers.send(id) }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: staging.path))?.isEmpty ?? true)
        #expect(transport.transfers.isEmpty)
    }

    @Test func requestHandlerReportsTransferFailures() {
        let transfers = service()
        transport.linkState = .ready(paired: true, installed: false, reachable: true)
        let handler = CompanionRequestHandler(surface: FakeWatchSurface(), transfers: transfers)
        let response = handler.handle(WatchFixture.request(.sendToWatch(discourseID: id)))
        #expect(response.errorMessage == WatchTransferService.Failure.watchAppNotInstalled.message)
    }

    @Test func finishedTransfersUpdateInventoryAndRemoveTheStagedCopy() throws {
        try seedDownload(id)
        let transfers = service()
        _ = try transfers.send(id)
        let staged = try #require(transport.transfers.first?.url)
        transfers.transferFinished(discourseID: id, fileURL: staged, succeeded: true)
        #expect(transfers.sending.isEmpty)
        #expect(transfers.inventory == [id])
        #expect(!FileManager.default.fileExists(atPath: staged.path))

        let other = WatchFixture.ids[1]
        try seedDownload(other)
        transport.outstanding.removeAll()
        _ = try transfers.send(other)
        transfers.transferFinished(discourseID: other, fileURL: try #require(transport.transfers.last?.url), succeeded: false)
        #expect(transfers.failures[other] != nil)
        #expect(!transfers.inventory.contains(other))
    }

    @Test func inventoryPersistsAcrossLaunches() {
        service().updateInventory(["a", "b", "a"])
        #expect(service().inventory == ["a", "b"])
    }

    @Test func refreshBeforeActivationKeepsStagedFiles() throws {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let leftover = staging.appendingPathComponent("leftover.mp3")
        try Data([1]).write(to: leftover)
        transport.linkState = .activating
        let transfers = service()
        transfers.refresh()
        #expect(FileManager.default.fileExists(atPath: leftover.path))
        transport.linkState = .ready(paired: true, installed: true, reachable: false)
        transfers.refresh()
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
    }

    @Test func metadataCarriesWhenThePhoneLastMovedThePosition() throws {
        try seedDownload(id)
        library.positions[id] = 321
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        library.savedAt[id] = at
        let transfers = service()
        #expect(try transfers.send(id) == .queued)
        let sent = try #require(transport.transfers.first)
        #expect(sent.file.resumeSavedAt == at)
    }

    @Test func aQueuedTalkStaysSendingWhileTheSessionCatchesUp() throws {
        try seedDownload(id)
        let transfers = service()
        #expect(try transfers.send(id) == .queued)
        transport.outstanding.removeAll()
        transfers.refresh()
        #expect(transfers.sending.contains(id))
        #expect(try transfers.send(id) == .alreadySending)
        #expect(transport.transfers.count == 1)
    }

    @Test func refreshKeepsACloneQueuedThisLaunchUntilItFinishes() throws {
        try seedDownload(id)
        let transfers = service()
        #expect(try transfers.send(id) == .queued)
        let staged = try #require(transport.transfers.first?.url)
        // The session's outstanding list has not caught up with the new transfer yet.
        transport.outstanding.removeAll()
        transfers.refresh()
        #expect(FileManager.default.fileExists(atPath: staged.path))
        transfers.transferFinished(discourseID: id, fileURL: staged, succeeded: true)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }
}

@MainActor
@Suite struct WatchPositionMergerTests {
    let defaults = WatchFixture.defaults()
    let id = WatchFixture.ids[0]

    private func report(_ position: Double, at seconds: TimeInterval, finished: Bool = false, id: String? = nil) -> CompanionPositionReport {
        CompanionPositionReport(discourseID: id ?? self.id, position: position, duration: 3600, finished: finished,
                                recordedAt: Date(timeIntervalSince1970: 1_800_000_000 + seconds))
    }

    @Test func newerReportApplies() {
        let state = WatchFixture.playbackState(defaults)
        let merger = WatchPositionMerger(playbackState: state, defaults: defaults) { nil }
        #expect(merger.apply(report(100, at: 0)) == .applied)
        #expect(merger.apply(report(250, at: 60)) == .applied)
        #expect(state.getPosition(discourseId: id) == 250)
        #expect(state.getDuration(discourseId: id) == 3600)
        #expect(state.recentlyPlayed.first == id)
    }

    @Test func olderOrRepeatedReportIsIgnoredEvenAfterRelaunch() {
        let state = WatchFixture.playbackState(defaults)
        let merger = WatchPositionMerger(playbackState: state, defaults: defaults) { nil }
        _ = merger.apply(report(500, at: 100))
        #expect(merger.apply(report(200, at: 50)) == .ignoredOlder)
        #expect(merger.apply(report(200, at: 100)) == .ignoredOlder)
        let relaunched = WatchPositionMerger(playbackState: state, defaults: defaults) { nil }
        #expect(relaunched.apply(report(10, at: 90)) == .ignoredOlder)
        #expect(state.getPosition(discourseId: id) == 500)
    }

    @Test func discoursePlayingOnThePhoneIsProtected() {
        let state = WatchFixture.playbackState(defaults)
        state.savePosition(discourseId: id, position: 900, duration: 3600, savedAt: Date(timeIntervalSince1970: 1_700_000_000))
        var moved: [TimeInterval] = []
        let merger = WatchPositionMerger(
            playbackState: state, defaults: defaults,
            loaded: { .init(discourseID: id, isPlaying: true) }, moveLoadedPlayer: { moved.append($0) }
        )
        #expect(merger.apply(report(100, at: 0)) == .ignoredPlayingOnPhone)
        #expect(merger.apply(report(3600, at: 1, finished: true)) == .ignoredPlayingOnPhone)
        #expect(state.getPosition(discourseId: id) == 900)
        #expect(!state.isCompleted(id))
        #expect(moved.isEmpty)
    }

    @Test func pausedLoadedDiscourseMovesToTheWatchPosition() {
        let state = WatchFixture.playbackState(defaults)
        state.savePosition(discourseId: id, position: 600, duration: 3600, savedAt: Date(timeIntervalSince1970: 1_700_000_000))
        var moved: [TimeInterval] = []
        var unloads = 0
        let merger = WatchPositionMerger(
            playbackState: state, defaults: defaults,
            loaded: { .init(discourseID: id, isPlaying: false) }, moveLoadedPlayer: { moved.append($0) },
            unloadLoadedPlayer: { unloads += 1 }
        )
        #expect(merger.apply(report(2700, at: 0)) == .applied)
        #expect(state.getPosition(discourseId: id) == 2700)
        #expect(moved == [2700])
        // Finished on the Watch: like a natural finish here, the paused talk unloads.
        #expect(merger.apply(report(3600, at: 60, finished: true)) == .completed)
        #expect(state.isCompleted(id))
        #expect(moved == [2700])
        #expect(unloads == 1)
    }

    /// The phone woke to play (AirPods, lock screen) just before the Watch's reports arrived.
    @Test func justResumedPhoneCatchesUpToTheWatch() {
        let state = WatchFixture.playbackState(defaults)
        let watchStopped = Date(timeIntervalSince1970: 1_800_000_000)
        let phoneResumed = watchStopped.addingTimeInterval(600)
        var clock = phoneResumed.addingTimeInterval(20)
        var loaded = WatchPositionMerger.LoadedDiscourse(
            discourseID: id, isPlaying: true, playingSince: phoneResumed, resumedFrom: 600,
            savedBeforeResume: watchStopped.addingTimeInterval(-3600)
        )
        var moved: [TimeInterval] = []
        let merger = WatchPositionMerger(
            playbackState: state, defaults: defaults, loaded: { loaded }, moveLoadedPlayer: { moved.append($0) },
            now: { clock }
        )
        let walk = CompanionPositionReport(discourseID: id, position: 2700, duration: 3600, finished: false,
                                           recordedAt: watchStopped)
        // The young stretch's own autosave is newer than the report; it must not block the catch-up.
        state.savePosition(discourseId: id, position: 615, duration: 3600, savedAt: phoneResumed.addingTimeInterval(10))
        #expect(merger.apply(walk) == .caughtUpPlayingPhone)
        #expect(moved == [2700])
        #expect(merger.apply(walk) == .ignoredOlder, "a repeated report applies once")

        // An established stretch, or a report made after the phone resumed, is left alone.
        let later = CompanionPositionReport(discourseID: id, position: 3000, duration: 3600, finished: false,
                                            recordedAt: phoneResumed.addingTimeInterval(5))
        #expect(merger.apply(later) == .ignoredPlayingOnPhone)
        clock = phoneResumed.addingTimeInterval(WatchPositionMerger.catchUpWindow + 1)
        let lateArrival = CompanionPositionReport(discourseID: id, position: 3100, duration: 3600, finished: false,
                                                  recordedAt: watchStopped.addingTimeInterval(1))
        #expect(merger.apply(lateArrival) == .ignoredPlayingOnPhone)
        #expect(moved == [2700])

        // Phone listening newer than the Watch's, before this stretch, still wins.
        clock = phoneResumed.addingTimeInterval(20)
        loaded.savedBeforeResume = watchStopped.addingTimeInterval(30)
        let stale = CompanionPositionReport(discourseID: id, position: 3200, duration: 3600, finished: false,
                                            recordedAt: watchStopped.addingTimeInterval(2))
        #expect(merger.apply(stale) == .ignoredPlayingOnPhone)
        #expect(moved == [2700])
    }

    @Test func catchUpNeedsARealGainAndNeverFinishesAPlayingTalk() {
        let state = WatchFixture.playbackState(defaults)
        let watchStopped = Date(timeIntervalSince1970: 1_800_000_000)
        let phoneResumed = watchStopped.addingTimeInterval(60)
        var moved: [TimeInterval] = []
        let merger = WatchPositionMerger(
            playbackState: state, defaults: defaults,
            loaded: { .init(discourseID: self.id, isPlaying: true, playingSince: phoneResumed, resumedFrom: 1000) },
            moveLoadedPlayer: { moved.append($0) }, now: { phoneResumed.addingTimeInterval(5) }
        )
        let small = CompanionPositionReport(discourseID: id, position: 1003, duration: 3600, finished: false,
                                            recordedAt: watchStopped)
        #expect(merger.apply(small) == .ignoredPlayingOnPhone)
        let finished = CompanionPositionReport(discourseID: id, position: 3600, duration: 3600, finished: true,
                                               recordedAt: watchStopped.addingTimeInterval(1))
        #expect(merger.apply(finished) == .ignoredPlayingOnPhone)
        #expect(moved.isEmpty)
        #expect(!state.isCompleted(id))
    }

    @Test func phoneListeningAfterTheReportWins() {
        let state = WatchFixture.playbackState(defaults)
        let merger = WatchPositionMerger(playbackState: state, defaults: defaults) { nil }
        let recorded = Date().addingTimeInterval(-3600)
        state.savePosition(discourseId: id, position: 3000, duration: 3600, savedAt: recorded.addingTimeInterval(600))
        let late = CompanionPositionReport(discourseID: id, position: 1200, duration: 3600, finished: false, recordedAt: recorded)
        let lateFinish = CompanionPositionReport(discourseID: id, position: 3600, duration: 3600, finished: true, recordedAt: recorded)
        #expect(merger.apply(late) == .ignoredPhoneNewer)
        #expect(merger.apply(lateFinish) == .ignoredPhoneNewer)
        #expect(state.getPosition(discourseId: id) == 3000)
        #expect(!state.isCompleted(id))
    }

    @Test func onlyAMovedPhonePositionCountsAsNewerListening() {
        let state = WatchFixture.playbackState(defaults)
        let merger = WatchPositionMerger(playbackState: state, defaults: defaults) { nil }
        state.savePosition(discourseId: id, position: 900, duration: 3600, savedAt: Date().addingTimeInterval(-7200))
        // Autosave rewrites a paused position every tick; that is not new listening.
        state.savePosition(discourseId: id, position: 900, duration: 3600)
        let report = { (position: Double, ago: TimeInterval) in
            CompanionPositionReport(discourseID: self.id, position: position, duration: 3600, finished: false,
                                    recordedAt: Date().addingTimeInterval(-ago))
        }
        #expect(merger.apply(report(1500, 3600)) == .applied)
        state.savePosition(discourseId: id, position: 1600, duration: 3600)
        #expect(merger.apply(report(2000, 1800)) == .ignoredPhoneNewer)
        #expect(state.getPosition(discourseId: id) == 1600)
    }

    @Test func clearingOnThePhoneBlocksAnOlderReport() {
        let state = WatchFixture.playbackState(defaults)
        let merger = WatchPositionMerger(playbackState: state, defaults: defaults) { nil }
        state.clearPosition(discourseId: id)
        let older = CompanionPositionReport(discourseID: id, position: 1200, duration: 3600, finished: false,
                                            recordedAt: Date().addingTimeInterval(-60))
        #expect(merger.apply(older) == .ignoredPhoneNewer)
        #expect(state.getPosition(discourseId: id) == 0)
    }

    @Test func finishedReportMarksTheDiscourseComplete() {
        let state = WatchFixture.playbackState(defaults)
        let merger = WatchPositionMerger(playbackState: state, defaults: defaults) { nil }
        _ = merger.apply(report(100, at: 0))
        #expect(merger.apply(report(3600, at: 10, finished: true)) == .completed)
        #expect(state.isCompleted(id))
        #expect(state.listenedCompleted.first == id)
        #expect(state.getPosition(discourseId: id) == 0)
        #expect(!state.recentlyPlayed.contains(id))
    }

    @Test func invalidReportsChangeNothing() throws {
        let state = WatchFixture.playbackState(defaults)
        let merger = WatchPositionMerger(playbackState: state, defaults: defaults) { nil }
        #expect(merger.apply(Data("{}".utf8)) == .ignoredMalformed)
        #expect(merger.apply(report(100, at: 0, id: "no-such-talk")) == .ignoredUnknownDiscourse)
        #expect(merger.apply(report(.nan, at: 0)) == .ignoredInvalidPosition)
        #expect(merger.apply(report(0, at: 0)) == .ignoredInvalidPosition)
        #expect(merger.lastApplied(for: id) == nil)
        #expect(state.recentlyPlayed.isEmpty)
    }
}
#endif
