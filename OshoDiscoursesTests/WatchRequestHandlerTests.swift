#if canImport(WatchConnectivity) && !targetEnvironment(macCatalyst)
import Foundation
import Testing
@testable import OshoDiscourses

@MainActor
@Suite struct WatchRequestHandlerTests {
    let surface = FakeWatchSurface()

    private func handler(transfers: WatchTransferService? = nil) -> CompanionRequestHandler {
        CompanionRequestHandler(surface: surface, transfers: transfers)
    }

    @Test func transportActionsNeedTheDisplayedDiscourse() {
        let handler = handler()
        let empty = handler.handle(WatchFixture.request(.setPlaying(false), expected: "a"))
        #expect(empty.errorMessage == CompanionRequestHandler.Failure.nothingLoaded.message)

        surface.currentDiscourseID = "b"
        let stale = handler.handle(WatchFixture.request(.skipForward, expected: "a"))
        #expect(stale.errorMessage == CompanionRequestHandler.Failure.staleDiscourse.message)
        let missing = handler.handle(WatchFixture.request(.skipBackward))
        #expect(missing.errorMessage == CompanionRequestHandler.Failure.staleDiscourse.message)
        #expect(surface.calls.isEmpty)

        for action in [CompanionAction.setPlaying(true), .skipForward, .skipBackward, .nextDiscourse, .previousDiscourse] {
            #expect(handler.handle(WatchFixture.request(action, expected: "b")).errorMessage == nil)
        }
        #expect(surface.calls == ["play", "forward 30", "backward 15", "next", "previous"])
    }

    @Test func rateIsClampedAndInvalidRatesRejected() {
        surface.currentDiscourseID = "a"
        let handler = handler()
        _ = handler.handle(WatchFixture.request(.setRate(3), expected: "a"))
        _ = handler.handle(WatchFixture.request(.setRate(0.1), expected: "a"))
        _ = handler.handle(WatchFixture.request(.setRate(1.25), expected: "a"))
        let nan = handler.handle(WatchFixture.request(.setRate(.nan), expected: "a"))
        #expect(surface.calls == ["rate 2.0", "rate 0.5", "rate 1.25"])
        #expect(nan.errorMessage != nil)
    }

    @Test func nextAtTheEndOfTheSeriesIsRejected() {
        surface.currentDiscourseID = "a"
        surface.hasNext = false
        let response = handler().handle(WatchFixture.request(.nextDiscourse, expected: "a"))
        #expect(response.errorMessage == CompanionRequestHandler.Failure.noNext.message)
        #expect(surface.calls.isEmpty)
    }

    @Test func playItemRoutesRowsAndMapsLauncherFailures() {
        let handler = handler()
        #expect(handler.handle(WatchFixture.request(.playItem(rowID: "d:abc"))).errorMessage == nil)
        #expect(handler.handle(WatchFixture.request(.playItem(rowID: "b:bm1"))).errorMessage == nil)
        #expect(surface.calls == ["play abc", "bookmark bm1"])
        #expect(handler.handle(WatchFixture.request(.playItem(rowID: "s:series"))).errorMessage
            == CompanionRequestHandler.Failure.notPlayable.message)
        #expect(handler.handle(WatchFixture.request(.playItem(rowID: "zz"))).errorMessage != nil)
        surface.launchFailure = .notDownloaded
        #expect(handler.handle(WatchFixture.request(.playItem(rowID: "d:abc"))).errorMessage
            == PlaybackLauncher.Failure.notDownloaded.message)
    }

    @Test func reusedRequestIDForAnotherActionIsRejected() {
        surface.currentDiscourseID = "a"
        let handler = handler()
        let id = UUID()
        _ = handler.handle(WatchFixture.request(.setPlaying(false), expected: "a", id: id))
        let reused = handler.handle(WatchFixture.request(.skipForward, expected: "a", id: id))
        #expect(reused.errorMessage != nil)
        #expect(surface.calls == ["pause"])
    }

    @Test func receiptWindowIsBounded() {
        surface.currentDiscourseID = "a"
        let handler = handler()
        let first = WatchFixture.request(.setPlaying(false), expected: "a")
        _ = handler.handle(first)
        for _ in 0..<CompanionRequestHandler.receiptCapacity { _ = handler.handle(WatchFixture.request(.snapshot)) }
        _ = handler.handle(first)
        #expect(surface.calls == ["pause", "pause"])
    }

    @Test func snapshotSequenceAdvancesOnlyOnChange() {
        let handler = handler()
        let a = handler.snapshot()
        let b = handler.snapshot()
        #expect(a == b)
        surface.now = FakeWatchSurface.nowPlaying("x")
        let c = handler.snapshot()
        #expect(c.sequence == a.sequence + 1)
        #expect(c.sessionID == a.sessionID)
        #expect(c.accentName == "blue")
        #expect(c.version == CompanionWire.version)
    }

    @Test func snapshotCarriesPhoneProgressForTalksOnTheWatch() {
        let defaults = WatchFixture.defaults()
        let transfers = WatchTransferService(sink: FakeWatchTransport(), library: FakeTransferLibrary(),
                                             defaults: defaults, stagingDirectory: WatchFixture.tempDirectory())
        let handler = CompanionRequestHandler(surface: surface, transfers: transfers)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        surface.saved = [
            CompanionSavedPosition(discourseID: "on-watch", position: 4200, finished: false, savedAt: at),
            CompanionSavedPosition(discourseID: "phone-only", position: 60, finished: false, savedAt: at),
        ]
        #expect(handler.snapshot().savedPositions == nil, "no inventory yet")
        transfers.updateInventory(["on-watch"])
        let snapshot = handler.snapshot()
        #expect(snapshot.savedPositions?.map(\.discourseID) == ["on-watch"])
        // Like the clock, a saved-position change alone is not semantic.
        var moved = snapshot
        moved.savedPositions = [CompanionSavedPosition(discourseID: "on-watch", position: 4300, finished: false, savedAt: at)]
        #expect(WatchPhoneSession.sameSemantics(moved, snapshot))
    }

    @Test func browsePassesTheWatchInventoryAndKeepsIt() {
        let defaults = WatchFixture.defaults()
        let transfers = WatchTransferService(sink: FakeWatchTransport(), library: FakeTransferLibrary(),
                                             defaults: defaults, stagingDirectory: WatchFixture.tempDirectory())
        let handler = handler(transfers: transfers)
        _ = handler.handle(WatchFixture.request(.browse(.continueListening), inventory: ["a", "b"]))
        #expect(surface.lastInventory == ["a", "b"])
        #expect(transfers.inventory == ["a", "b"])
        #expect(defaults.stringArray(forKey: WatchTransferService.inventoryKey) == ["a", "b"])
        // A request without inventory falls back to the last one the Watch reported.
        _ = handler.handle(WatchFixture.request(.browse(.downloads)))
        #expect(surface.lastInventory == ["a", "b"])
    }

    @Test func longRowTextIsShortenedBeforeRowsAreDropped() throws {
        surface.rows = (0..<60).map { index in
            CompanionRow(id: "d:\(index)", kind: .discourse, title: String(repeating: "T", count: 3000),
                         subtitle: String(repeating: "S", count: 3000))
        }
        let response = handler().handle(WatchFixture.request(.browse(.downloads)))
        #expect(try CompanionWire.encode(response).count <= CompanionWire.maximumPayloadBytes)
        #expect(response.page?.rows.count == 60)
        #expect(response.page?.isTruncated == false)
    }

    @Test func smallPagesPassThroughUnchanged() {
        surface.rows = [CompanionRow(id: "d:1", kind: .discourse, title: "One", subtitle: "Series")]
        let response = handler().handle(WatchFixture.request(.browse(.downloads)))
        #expect(response.page?.rows == surface.rows)
        #expect(response.page?.isTruncated == false)
    }
}
#endif
