#if canImport(WatchConnectivity) && !targetEnvironment(macCatalyst)
import Foundation
import Testing
@testable import OshoDiscourses

// MARK: Shared fakes for the Watch phone-side suites

@MainActor
final class FakeWatchSurface: WatchPlaybackSurface {
    var currentDiscourseID: String?
    var hasNext = true
    var accentName: String? = "blue"
    var now: CompanionNowPlaying?
    var rows: [CompanionRow] = []
    var launchFailure: PlaybackLauncher.Failure?
    private(set) var calls: [String] = []
    private(set) var lastInventory: Set<String> = []

    func nowPlaying() -> CompanionNowPlaying? { now }
    var saved: [CompanionSavedPosition] = []
    func savedPositions(for discourseIDs: Set<String>) -> [CompanionSavedPosition] {
        saved.filter { discourseIDs.contains($0.discourseID) }
    }

    func page(for location: CompanionLocation, watchInventory: Set<String>, maximumRows: Int) -> CompanionPage {
        lastInventory = watchInventory
        let bounded = Array(rows.prefix(maximumRows))
        return CompanionPage(location: location, title: "Page", rows: bounded,
                             isTruncated: bounded.count < rows.count, emptyMessage: "Empty")
    }

    func setPlaying(_ playing: Bool) { calls.append(playing ? "play" : "pause") }
    func skipForward(_ seconds: TimeInterval) { calls.append("forward \(Int(seconds))") }
    func skipBackward(_ seconds: TimeInterval) { calls.append("backward \(Int(seconds))") }
    func nextDiscourse() { calls.append("next") }
    func previousDiscourse() { calls.append("previous") }
    func setRate(_ rate: Float) { calls.append("rate \(rate)") }
    func playDiscourse(_ discourseID: String) throws(PlaybackLauncher.Failure) {
        if let launchFailure { throw launchFailure }
        calls.append("play \(discourseID)")
    }
    func playBookmark(_ bookmarkID: String) throws(PlaybackLauncher.Failure) {
        if let launchFailure { throw launchFailure }
        calls.append("bookmark \(bookmarkID)")
    }

    static func nowPlaying(_ id: String, isPlaying: Bool = true, elapsed: Double = 0) -> CompanionNowPlaying {
        CompanionNowPlaying(discourseID: id, title: "Title", series: "Series", isPlaying: isPlaying,
                            elapsed: elapsed, duration: 3600, rate: 1, hasNext: true, hasPrevious: false,
                            sleepTimerLabel: nil)
    }
}

@MainActor
final class FakeWatchTransport: WatchPhoneTransport {
    var onEvent: (@MainActor (WatchTransportEvent) -> Void)?
    var linkState: WatchLinkState = .ready(paired: true, installed: true, reachable: true)
    var failsContext = false
    var failsTransfer = false
    var outstanding: Set<String> = []
    private(set) var contexts: [CompanionSnapshot] = []
    private(set) var transfers: [(url: URL, file: CompanionOfflineFile)] = []

    func activate() {}

    func updateApplicationContext(_ data: Data) throws {
        if failsContext { throw WatchTransportFailure.unavailable }
        contexts.append(try CompanionWire.decode(CompanionSnapshot.self, from: data))
    }

    func transferFile(_ url: URL, metadata: Data) throws {
        if failsTransfer { throw WatchTransportFailure.unavailable }
        let file = try CompanionWire.decode(CompanionOfflineFile.self, from: metadata)
        transfers.append((url, file))
        outstanding.insert(file.discourseID)
    }

    func outstandingTransferDiscourseIDs() -> Set<String> { outstanding }
}

@MainActor
final class FakeWatchScheduler: WatchScheduling {
    private(set) var pending: [(delay: TimeInterval, action: @MainActor () -> Void)] = []
    private(set) var cancellations = 0

    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        pending.append((seconds, action))
        let index = pending.count - 1
        return { [weak self] in
            guard let self, self.pending.indices.contains(index) else { return }
            self.cancellations += 1
            self.pending[index].action = {}
        }
    }

    func fireAll() {
        let actions = pending.map(\.action)
        pending.removeAll()
        actions.forEach { $0() }
    }
}

@MainActor
final class FakeTransferLibrary: WatchTransferLibrary {
    var files: [String: URL] = [:]
    var positions: [String: Double] = [:]
    var durations: [String: Double] = [:]
    func localFileURL(for discourseID: String) -> URL? { files[discourseID] }
    func resumePosition(for discourseID: String) -> Double { positions[discourseID] ?? 0 }
    func duration(for discourseID: String) -> Double { durations[discourseID] ?? 0 }
    var savedAt: [String: Date] = [:]
    func resumeSavedAt(for discourseID: String) -> Date? { savedAt[discourseID] }
}

final class WatchReplyBox: @unchecked Sendable {
    var data: Data?
    var count = 0
}

enum WatchFixture {
    static let ids: [String] = Array(Catalog.allDiscourses().prefix(3).map(\.id))

    static func defaults() -> UserDefaults {
        let name = "watch-phone-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    static func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("watch-phone-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    static func playbackState(_ defaults: UserDefaults) -> PlaybackStateService {
        PlaybackStateService(defaults: defaults, recordListeningTime: { _ in }, saveListeningStats: {})
    }

    static func request(_ action: CompanionAction, expected: String? = nil, inventory: [String]? = nil,
                        id: UUID = UUID(), version: Int = CompanionWire.version) -> CompanionRequest {
        CompanionRequest(version: version, id: id, action: action, expectedDiscourseID: expected, watchInventory: inventory)
    }

    static func encode(_ request: CompanionRequest) -> Data { try! JSONEncoder().encode(request) }
}

// MARK: Session: wire validation, replies and publication

@MainActor
@Suite struct WatchPhoneSessionTests {
    let surface = FakeWatchSurface()
    let transport = FakeWatchTransport()
    let scheduler = FakeWatchScheduler()
    let clockBox = ClockBox()

    final class ClockBox { var now: TimeInterval = 100 }

    private func session(transfers: WatchTransferService? = nil, merger: WatchPositionMerger? = nil)
        -> (WatchPhoneSession, CompanionRequestHandler) {
        let handler = CompanionRequestHandler(surface: surface, transfers: transfers)
        let session = WatchPhoneSession()
        let clock = clockBox
        session.configure(transport: transport, handler: handler, transfers: transfers, merger: merger,
                          clock: { clock.now }, scheduler: scheduler)
        return (session, handler)
    }

    private func send(_ data: Data, to session: WatchPhoneSession, receivedAt: TimeInterval? = nil) -> WatchReplyBox {
        let box = WatchReplyBox()
        let reply = WatchReply(receivedAt: receivedAt ?? clockBox.now) { data in
            box.data = data
            box.count += 1
        }
        session.handle(data, reply: reply)
        return box
    }

    @Test func malformedInputGetsAnEmptyReplyAndRunsNothing() {
        let (session, handler) = session()
        let box = send(Data("not json".utf8), to: session)
        #expect(box.data == Data())
        #expect(box.count == 1)
        #expect(handler.executedCount == 0)
    }

    @Test func oversizedInputGetsAnEmptyReply() {
        let (session, handler) = session()
        var request = WatchFixture.request(.snapshot)
        request.watchInventory = Array(repeating: String(repeating: "x", count: 100), count: 700)
        let data = WatchFixture.encode(request)
        #expect(data.count > CompanionWire.maximumPayloadBytes)
        let box = send(data, to: session)
        #expect(box.data == Data())
        #expect(handler.executedCount == 0)
    }

    @Test func versionMismatchIsACorrelatedRejection() throws {
        surface.currentDiscourseID = "x"
        let (session, handler) = session()
        let request = WatchFixture.request(.setPlaying(false), expected: "x", version: CompanionWire.version + 1)
        let box = send(WatchFixture.encode(request), to: session)
        let response = try CompanionWire.decode(CompanionResponse.self, from: try #require(box.data))
        #expect(response.requestID == request.id)
        #expect(response.errorMessage != nil)
        #expect(surface.calls.isEmpty)
        #expect(handler.executedCount == 0)
    }

    @Test func expiredRequestIsNotExecuted() {
        surface.currentDiscourseID = "x"
        let (session, handler) = session()
        let request = WatchFixture.request(.setPlaying(false), expected: "x")
        let box = send(WatchFixture.encode(request), to: session, receivedAt: clockBox.now - WatchReply.deadline - 1)
        #expect(box.data == Data())
        #expect(surface.calls.isEmpty)
        #expect(handler.executedCount == 0)
    }

    @Test func resentRequestReturnsTheCachedResponseWithoutRunningTwice() throws {
        surface.currentDiscourseID = "x"
        let (session, handler) = session()
        let request = WatchFixture.request(.setPlaying(false), expected: "x")
        let first = try CompanionWire.decode(CompanionResponse.self, from: try #require(send(WatchFixture.encode(request), to: session).data))
        surface.now = FakeWatchSurface.nowPlaying("x", isPlaying: false)
        let second = try CompanionWire.decode(CompanionResponse.self, from: try #require(send(WatchFixture.encode(request), to: session).data))
        #expect(surface.calls == ["pause"])
        #expect(handler.executedCount == 1)
        #expect(first == second)
    }

    @Test func browseReplyStaysInsideThePayloadBound() throws {
        surface.rows = (0..<60).map { index in
            // Ids are never shortened, so long ids force rows to be dropped as well.
            CompanionRow(id: "d:\(index)" + String(repeating: "i", count: 1500), kind: .discourse,
                         title: String(repeating: "T", count: 3000),
                         subtitle: String(repeating: "S", count: 3000))
        }
        let (session, _) = session()
        let request = WatchFixture.request(.browse(.downloads))
        let data = try #require(send(WatchFixture.encode(request), to: session).data)
        #expect(data.count <= CompanionWire.maximumPayloadBytes)
        let page = try #require(try CompanionWire.decode(CompanionResponse.self, from: data).page)
        #expect(page.isTruncated)
        #expect(!page.rows.isEmpty)
        #expect(page.rows.count < 60)
        #expect(page.rows.allSatisfy { $0.title.count <= 80 && $0.subtitle.count <= 60 })
    }

    // MARK: Publication

    @Test func positionTicksAreThrottledWithOneTrailingUpdate() throws {
        surface.now = FakeWatchSurface.nowPlaying("x", elapsed: 0)
        let (session, _) = session()
        session.snapshotDidChange()
        #expect(transport.contexts.count == 1)
        for tick in 1...18 {
            clockBox.now += 0.5
            surface.now = FakeWatchSurface.nowPlaying("x", elapsed: Double(tick) * 0.5)
            session.snapshotDidChange()
        }
        #expect(transport.contexts.count == 1)
        #expect(scheduler.pending.count == 1)
        clockBox.now += 1
        scheduler.fireAll()
        #expect(transport.contexts.count == 2)
        #expect(transport.contexts.last?.nowPlaying?.elapsed == 9)
        let sequences = transport.contexts.map(\.sequence)
        #expect(sequences == sequences.sorted() && Set(sequences).count == sequences.count)
    }

    @Test func semanticChangePublishesImmediately() {
        surface.now = FakeWatchSurface.nowPlaying("x", elapsed: 0)
        let (session, _) = session()
        session.snapshotDidChange()
        clockBox.now += 1
        surface.now = FakeWatchSurface.nowPlaying("x", isPlaying: false, elapsed: 1)
        session.snapshotDidChange()
        clockBox.now += 1
        surface.accentName = "teal"
        session.snapshotDidChange()
        clockBox.now += 1
        var timed = FakeWatchSurface.nowPlaying("x", isPlaying: false, elapsed: 1)
        timed.sleepTimerLabel = "12 min"
        surface.now = timed
        session.snapshotDidChange()
        #expect(transport.contexts.count == 4)
        #expect(transport.contexts.last?.accentName == "teal")
    }

    @Test func unreachableWatchGetsSemanticContextButNoPositionTicks() {
        transport.linkState = .ready(paired: true, installed: true, reachable: false)
        surface.now = FakeWatchSurface.nowPlaying("x", elapsed: 0)
        let (session, _) = session()
        session.snapshotDidChange()
        #expect(transport.contexts.count == 1)
        clockBox.now += 30
        surface.now = FakeWatchSurface.nowPlaying("x", elapsed: 30)
        session.snapshotDidChange()
        #expect(transport.contexts.count == 1)
        #expect(scheduler.pending.isEmpty)
        surface.now = FakeWatchSurface.nowPlaying("y", elapsed: 0)
        session.snapshotDidChange()
        #expect(transport.contexts.count == 2)
    }

    @Test func nothingIsPublishedWithoutAnInstalledWatchApp() {
        transport.linkState = .ready(paired: true, installed: false, reachable: false)
        surface.now = FakeWatchSurface.nowPlaying("x")
        let (session, _) = session()
        session.snapshotDidChange()
        #expect(transport.contexts.isEmpty)
        #expect(session.publicationAttempts == 0)
    }

    @Test func failedContextRetriesOnTheBoundedCadence() {
        transport.failsContext = true
        surface.now = FakeWatchSurface.nowPlaying("x")
        let (session, _) = session()
        session.snapshotDidChange()
        #expect(transport.contexts.isEmpty)
        #expect(scheduler.pending.count == 1)
        #expect(scheduler.pending.first?.delay == WatchPhoneSession.positionPublicationInterval)
        transport.failsContext = false
        clockBox.now += 10
        scheduler.fireAll()
        #expect(transport.contexts.count == 1)
    }

    @Test func positionReportEventsReachTheMerger() throws {
        let defaults = WatchFixture.defaults()
        let state = WatchFixture.playbackState(defaults)
        let merger = WatchPositionMerger(playbackState: state, defaults: defaults) { nil }
        let (session, _) = session(merger: merger)
        let id = WatchFixture.ids[0]
        let report = CompanionPositionReport(discourseID: id, position: 120, duration: 3600, finished: false, recordedAt: Date())
        transport.onEvent?(.positionReport(try JSONEncoder().encode(report)))
        #expect(state.getPosition(discourseId: id) == 120)
        withExtendedLifetime(session) {}
    }
}
#endif
