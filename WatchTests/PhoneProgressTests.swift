import Foundation
import Testing
@testable import OshoDiscoursesWatch

/// The Watch taking newer phone listening for its saved talks, and never echoing it back.
@MainActor
struct PhoneProgressTests {
    @Test func theLoadedTalkKeepsItsPositionUntilThePlayerReleasesIt() throws {
        let (store, root) = try Fixtures.temporaryStore()
        try Fixtures.receive(Fixtures.offlineFile("loaded", resume: 100, duration: 5_400, savedAt: Fixtures.t0),
                             into: store, scratch: root)
        try Fixtures.receive(Fixtures.offlineFile("other", resume: 50, savedAt: Fixtures.t0), into: store, scratch: root)
        let library = OfflineLibrary(store: store)
        var loaded: String? = "loaded"
        library.loadedDiscourseID = { loaded }

        let changed = library.adoptPhonePositions([Fixtures.saved("loaded", 900, at: 60), Fixtures.saved("other", 700, at: 60)])
        #expect(changed == ["other"])
        #expect(library.entry(for: "loaded")?.position == 100)
        #expect(library.entry(for: "other")?.position == 700)

        // Released, the talk catches up from what the phone already sent, without another snapshot.
        loaded = nil
        #expect(library.applyPhonePositions() == ["loaded"])
        #expect(library.entry(for: "loaded")?.startPosition == 900)
    }

    @Test func everyIncomingSnapshotFeedsAdoptionAndNoneOfItIsReported() async throws {
        let (store, root) = try Fixtures.temporaryStore()
        try Fixtures.receive(Fixtures.offlineFile("d1", resume: 100, savedAt: Fixtures.t0), into: store, scratch: root)
        let library = OfflineLibrary(store: store)
        let transport = TestTransport()
        let reporter = PositionReporter { transport.transferUserInfo($0) }
        let player = OfflinePlayer(library: library, reporter: reporter)
        let model = WatchCompanionModel(
            client: WatchRequestClient(transport: transport, waitForDeadline: neverDeadline),
            accentStore: WatchAccentStore(defaults: Fixtures.isolatedDefaults()),
            heartbeatInterval: .seconds(3_600), inventory: { library.inventory }
        )
        WatchAppSession.wire(model: model, offline: library, reporter: reporter)

        // Context from the phone process on screen.
        transport.onEvent?(.applicationContext(try CompanionWire.encode(
            Fixtures.snapshot(session: Fixtures.sessionA, saved: [Fixtures.saved("d1", 300, at: 10)])
        )))
        #expect(library.entry(for: "d1")?.position == 300)

        // A new phone process is held back from the display until a reply confirms it; its progress is not.
        transport.onEvent?(.applicationContext(try CompanionWire.encode(
            Fixtures.snapshot(session: Fixtures.sessionB, saved: [Fixtures.saved("d1", 400, at: 20)])
        )))
        #expect(model.timeline.snapshot?.sessionID == Fixtures.sessionA)
        #expect(library.entry(for: "d1")?.position == 400)

        // Every reply's snapshot carries it too.
        transport.automaticResponse = { request in
            Fixtures.response(for: request, snapshot: Fixtures.snapshot(
                session: Fixtures.sessionB, sequence: 2, saved: [Fixtures.saved("d1", 500, at: 30)]
            ))
        }
        model.setForeground(true)
        try await waitUntil { library.entry(for: "d1")?.position == 500 }
        #expect(transport.requests.first?.watchInventory == ["d1"])
        #expect(library.entry(for: "d1")?.positionUpdatedAt == Fixtures.t0 + 30)
        #expect(transport.userInfos.isEmpty, "Progress taken from the phone is never reported back to it")
        model.setForeground(false)
        withExtendedLifetime(player) {}
    }

    @Test func onlyNewListeningIsReportedAndItsEchoIsNotTakenBack() throws {
        let (store, root) = try Fixtures.temporaryStore()
        try Fixtures.receive(Fixtures.offlineFile("d1", resume: 100, savedAt: Fixtures.t0), into: store, scratch: root)
        let library = OfflineLibrary(store: store)
        library.adoptPhonePositions([Fixtures.saved("d1", 300, at: 60)])
        let transport = TestTransport()
        var now = Fixtures.t0 + 120
        var uptime: TimeInterval = 1_000
        let recorder = ListeningRecorder(
            library: library, reporter: PositionReporter { transport.transferUserInfo($0) },
            uptime: { uptime }, clock: { now }
        )
        recorder.load(try #require(library.entry(for: "d1")))
        recorder.playbackStarted()

        // Pausing or leaving the app without listening sends nothing, so the phone keeps any newer listening.
        recorder.save("d1", position: 300.4, duration: 600, finished: false, report: .pause)
        #expect(transport.userInfos.isEmpty)

        now = Fixtures.t0 + 180
        uptime += 30
        recorder.save("d1", position: 330, duration: 600, finished: false, report: .pause)
        let report = try CompanionWire.decode(CompanionPositionReport.self, from: try #require(transport.userInfos.first))
        #expect(report.position == 330)
        #expect(report.recordedAt == Fixtures.t0 + 180)
        #expect(library.entry(for: "d1")?.positionUpdatedAt == report.recordedAt)

        now = Fixtures.t0 + 240
        uptime += 30
        recorder.save("d1", position: 330, duration: 600, finished: false, report: .pause)
        #expect(transport.userInfos.count == 1)

        // The phone stores a report at its recorded time, so the next snapshot's copy is not newer.
        let echo = CompanionSavedPosition(discourseID: "d1", position: 330, finished: false, savedAt: report.recordedAt)
        #expect(library.adoptPhonePositions([echo]).isEmpty)
    }
}
