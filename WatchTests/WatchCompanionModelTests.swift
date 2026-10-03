import Foundation
import Testing
@testable import OshoDiscoursesWatch

@MainActor
struct WatchCompanionModelTests {
    private func makeModel(
        _ transport: TestTransport, clock: TestClock? = nil, inventory: [String] = ["saved-1"],
        deadline: @escaping @Sendable () async throws -> Void = neverDeadline,
        defaults: UserDefaults = Fixtures.isolatedDefaults()
    ) -> WatchCompanionModel {
        let clock = clock ?? TestClock(live: true)
        let uptime: @MainActor () -> TimeInterval = { clock.now }
        let client = WatchRequestClient(transport: transport, waitForDeadline: deadline, uptime: uptime)
        return WatchCompanionModel(
            client: client, uptime: uptime, accentStore: WatchAccentStore(defaults: defaults),
            heartbeatInterval: .seconds(3_600), inventory: { inventory }
        )
    }

    private func autoSnapshot(_ transport: TestTransport, _ snapshot: @escaping () -> CompanionSnapshot) {
        transport.automaticResponse = { request in
            request.action == .snapshot ? Fixtures.response(for: request, snapshot: snapshot()) : nil
        }
    }

    @Test func foregroundReadsTheSnapshotWithTheWatchInventory() async throws {
        let transport = TestTransport()
        autoSnapshot(transport) { Fixtures.snapshot() }
        let model = makeModel(transport)
        model.setForeground(true)
        try await waitUntil { model.isCurrent }
        #expect(transport.requests.first?.action == .snapshot)
        #expect(transport.requests.first?.watchInventory == ["saved-1"])
        model.setForeground(false)
    }

    @Test func transportCommandCarriesTheDisplayedDiscourseAndWaitsForThePhone() async throws {
        let transport = TestTransport()
        autoSnapshot(transport) { Fixtures.snapshot(playing: false) }
        let model = makeModel(transport)
        model.setForeground(true)
        try await waitUntil { model.isCurrent }
        let displayed = try #require(model.timeline.snapshot)
        let task = Task { await model.command(.setPlaying(true), displayed: displayed) }
        try await waitUntil { transport.requests.contains { $0.action == .setPlaying(true) } }
        let index = transport.requests.firstIndex { $0.action == .setPlaying(true) }!
        #expect(transport.requests[index].expectedDiscourseID == "mustard-seed-3")
        #expect(transport.requests[index].watchInventory == ["saved-1"])
        #expect(!model.isPlaying, "No optimistic flip before the phone replies")
        #expect(!model.canControl)
        transport.reply(at: index, snapshot: Fixtures.snapshot(sequence: 2, playing: true))
        #expect(await task.value)
        #expect(model.isPlaying)
        model.setForeground(false)
    }

    @Test func ambiguousMutationDisablesControlsAndRefreshesWithoutResending() async throws {
        let transport = TestTransport()
        var phone = Fixtures.snapshot(playing: false)
        autoSnapshot(transport) { phone }
        let model = makeModel(transport)
        model.setForeground(true)
        try await waitUntil { model.isCurrent }
        let displayed = try #require(model.timeline.snapshot)
        transport.automaticResponse = nil
        let task = Task { await model.command(.setPlaying(true), displayed: displayed) }
        try await waitUntil { transport.requests.contains { $0.action == .setPlaying(true) } }
        let index = transport.requests.firstIndex { $0.action == .setPlaying(true) }!
        transport.fail(at: index)
        #expect(await task.value == false)
        #expect(model.needsReconciliation)
        #expect(!model.canControl)
        // Mutations stay refused until the fresh read lands.
        #expect(await model.command(.skipForward, displayed: displayed) == false)
        try await waitUntil { transport.requests.count > index + 1 }
        let refresh = transport.requests.count - 1
        #expect(transport.requests[refresh].action == .snapshot)
        phone = Fixtures.snapshot(sequence: 2, playing: true)
        transport.reply(at: refresh, snapshot: phone)
        try await waitUntil { !model.needsReconciliation }
        #expect(model.canControl)
        #expect(model.isPlaying)
        #expect(transport.requests.filter { $0.action == .setPlaying(true) }.count == 1)
        #expect(model.notice == "Updated from iPhone. Check the player before trying again.")
        model.setForeground(false)
    }

    @Test func timeoutIsAlsoAmbiguous() async throws {
        let transport = TestTransport()
        autoSnapshot(transport) { Fixtures.snapshot() }
        let model = makeModel(transport, deadline: { try await Task.sleep(for: .milliseconds(40)) })
        model.setForeground(true)
        try await waitUntil { model.isCurrent }
        let displayed = try #require(model.timeline.snapshot)
        transport.automaticResponse = nil
        #expect(await model.command(.nextDiscourse, displayed: displayed) == false)
        #expect(model.needsReconciliation)
        #expect(transport.requests.filter { $0.action == .nextDiscourse }.count == 1)
        model.setForeground(false)
    }

    @Test func staleDisplayIsRejectedLocally() async throws {
        let transport = TestTransport()
        var phone = Fixtures.snapshot(id: "first")
        autoSnapshot(transport) { phone }
        let model = makeModel(transport)
        model.setForeground(true)
        try await waitUntil { model.isCurrent }
        let displayed = try #require(model.timeline.snapshot)
        phone = Fixtures.snapshot(sequence: 2, id: "second")
        await model.refresh()
        #expect(model.nowPlaying?.discourseID == "second")
        #expect(await model.command(.skipForward, displayed: displayed) == false)
        #expect(!transport.requests.contains { $0.action == .skipForward })
        #expect(model.notice == WatchCompanionModel.staleMessage)
        model.setForeground(false)
    }

    @Test func phoneRejectionShowsItsMessage() async throws {
        let transport = TestTransport()
        transport.automaticResponse = { request in
            Fixtures.response(
                for: request, snapshot: Fixtures.snapshot(),
                error: request.action.isReadOnly ? nil : "That talk isn't downloaded on iPhone."
            )
        }
        let model = makeModel(transport)
        model.setForeground(true)
        try await waitUntil { model.isCurrent }
        let row = CompanionRow(id: "d:x", kind: .discourse, title: "X", subtitle: "")
        #expect(await model.play(row) == false)
        #expect(model.notice == "That talk isn't downloaded on iPhone.")
        #expect(!model.needsReconciliation)
        model.setForeground(false)
    }

    @Test func playItemSendsTheRowIDWithoutAnExpectedDiscourse() async throws {
        let transport = TestTransport()
        transport.automaticResponse = { Fixtures.response(for: $0, snapshot: Fixtures.snapshot()) }
        let model = makeModel(transport)
        model.setForeground(true)
        try await waitUntil { model.isCurrent }
        let row = CompanionRow(id: "b:bookmark-1", kind: .bookmark, title: "Awareness", subtitle: "")
        #expect(await model.play(row))
        let play = try #require(transport.requests.first { $0.action == .playItem(rowID: "b:bookmark-1") })
        #expect(play.expectedDiscourseID == nil)
        model.setForeground(false)
    }

    @Test func saveToWatchStaysPendingUntilTheFileArrives() async throws {
        let transport = TestTransport()
        transport.automaticResponse = { Fixtures.response(for: $0, snapshot: Fixtures.snapshot()) }
        let model = makeModel(transport, inventory: [])
        var forwarded = 0
        model.onOfflineEvent = { _ in forwarded += 1 }
        model.setForeground(true)
        try await waitUntil { model.isCurrent }
        #expect(await model.saveToWatch(discourseID: "tao-7", title: "Tao #7"))
        #expect(transport.requests.contains { $0.action == .sendToWatch(discourseID: "tao-7") })
        #expect(model.requestedTransfers["tao-7"] == "Tao #7")
        let entry = OfflineEntry(discourseID: "tao-7", title: "Tao #7", series: "Tao", duration: 1, fileName: "f.mp3",
                                 byteCount: 1, addedAt: Date(), position: 0, finished: false)
        transport.onEvent?(.offlineFileStored(entry))
        #expect(model.requestedTransfers.isEmpty)
        #expect(forwarded == 1)
        model.setForeground(false)
    }

    @Test func browseStoresThePageForItsLocation() async throws {
        let transport = TestTransport()
        let page = CompanionPage(location: .bookmarks, title: "Bookmarks", rows: [], isTruncated: false,
                                 emptyMessage: "Bookmarks for downloaded discourses appear here.")
        transport.automaticResponse = { request in
            Fixtures.response(for: request, snapshot: Fixtures.snapshot(),
                              page: request.action == .browse(.bookmarks) ? page : nil)
        }
        let model = makeModel(transport)
        model.setForeground(true)
        try await waitUntil { model.isCurrent }
        await model.loadPage(.bookmarks)
        #expect(model.pages[.bookmarks] == page)
        await model.loadPage(.downloads)
        #expect(model.pages[.downloads] == nil)
        #expect(model.pageErrors[.downloads] != nil)
        model.setForeground(false)
    }

    @Test func disconnectedCachedPlaybackIsLastSeenAndFrozen() throws {
        let transport = TestTransport()
        transport.state = .ready(reachable: false, installed: true, needsUnlock: false)
        let clock = TestClock()
        let model = makeModel(transport, clock: clock)
        model.setForeground(true)
        transport.onEvent?(.applicationContext(try CompanionWire.encode(Fixtures.snapshot())))
        clock.advance(30)
        #expect(model.nowPlaying != nil)
        #expect(!model.isCurrent)
        #expect(!model.canControl)
        #expect(model.position == 42)
        #expect(model.connectionTitle == "Open Osho Talks on iPhone")
        #expect(transport.sent.isEmpty)
        model.setForeground(false)
    }

    @Test func connectionCopyIsDistinctPerState() {
        let transport = TestTransport()
        let model = makeModel(transport)
        var titles: Set<String> = []
        for state: WatchConnectionState in [
            .activating,
            .ready(reachable: true, installed: false, needsUnlock: false),
            .ready(reachable: false, installed: true, needsUnlock: true),
            .ready(reachable: false, installed: true, needsUnlock: false),
        ] {
            transport.state = state
            model.start()
            transport.onEvent?(.stateChanged(state))
            titles.insert(model.connectionTitle)
        }
        #expect(titles == ["Connecting to iPhone…", "Install Osho Talks on iPhone", "Unlock your iPhone",
                           "Open Osho Talks on iPhone"])
    }
}
