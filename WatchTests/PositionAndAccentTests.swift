import Foundation
import Testing
@testable import OshoDiscoursesWatch

struct PositionReportPolicyTests {
    private func check(_ policy: inout PositionReportPolicy, _ reason: PositionReportPolicy.Reason, at time: TimeInterval) -> Bool {
        policy.shouldReport(reason, at: time)
    }

    @Test func ticksReportAtMostOncePerMinuteAfterPlaybackStarts() {
        var policy = PositionReportPolicy()
        policy.playbackStarted(at: 0)
        #expect(check(&policy, .tick, at: 10) == false)
        #expect(check(&policy, .tick, at: 59.9) == false)
        #expect(check(&policy, .tick, at: 60) == true)
        #expect(check(&policy, .tick, at: 100) == false)
        #expect(check(&policy, .tick, at: 120) == true)
    }

    @Test func pauseAndFinishAlwaysReportAndRestartTheInterval() {
        var policy = PositionReportPolicy()
        policy.playbackStarted(at: 0)
        #expect(check(&policy, .pause, at: 5) == true)
        #expect(check(&policy, .pause, at: 6) == true)
        #expect(check(&policy, .finish, at: 7) == true)
        #expect(check(&policy, .tick, at: 60) == false)
        #expect(check(&policy, .tick, at: 67) == true)
    }
}

@MainActor
struct PositionReporterTests {
    private func report(_ id: String, _ position: Double, at seconds: TimeInterval = 0) -> CompanionPositionReport {
        CompanionPositionReport(discourseID: id, position: position, duration: 600, finished: false,
                                recordedAt: Date(timeIntervalSince1970: seconds))
    }

    @Test func reportsAreEncodedForTransferUserInfo() throws {
        let transport = TestTransport()
        let reporter = PositionReporter { transport.transferUserInfo($0) }
        reporter.report(report("d1", 42))
        let sent = try CompanionWire.decode(CompanionPositionReport.self, from: try #require(transport.userInfos.first))
        #expect(sent == report("d1", 42))
    }

    @Test func unsentReportsKeepTheNewestPerTalkAndFlushLater() {
        let transport = TestTransport()
        transport.acceptsUserInfo = false
        let reporter = PositionReporter { transport.transferUserInfo($0) }
        reporter.report(report("d1", 10, at: 1))
        reporter.report(report("d1", 20, at: 2))
        reporter.report(report("d2", 5, at: 3))
        #expect(reporter.unsent.count == 2)
        #expect(reporter.unsent["d1"]?.position == 20)
        transport.acceptsUserInfo = true
        reporter.flush()
        #expect(reporter.unsent.isEmpty)
        let ids = transport.userInfos.compactMap { try? CompanionWire.decode(CompanionPositionReport.self, from: $0).discourseID }
        #expect(ids == ["d1", "d2"])
    }
}

@MainActor
struct WatchAccentTests {
    @Test func everyPhoneAccentMapsToADistinctSystemColor() {
        let names = ["blue", "teal", "purple", "pink", "orange", "green", "indigo", "mint"]
        #expect(WatchAccent.allCases.map(\.rawValue) == names)
        #expect(WatchAccent.blue.color == .blue)
        #expect(WatchAccent.mint.color == .mint)
        #expect(Set(WatchAccent.allCases.map { "\($0.color)" }).count == names.count)
    }

    @Test func freshWatchUsesOrangeAndUnknownNamesKeepTheLastAccent() {
        let defaults = Fixtures.isolatedDefaults()
        let store = WatchAccentStore(defaults: defaults)
        #expect(store.load() == .orange)
        #expect(store.apply("teal") == .teal)
        #expect(store.apply("chartreuse") == nil)
        #expect(store.apply(nil) == nil)
        #expect(WatchAccentStore(defaults: defaults).load() == .teal)
    }

    @Test func acceptedSnapshotsRestyleAndPersistTheAccent() async throws {
        let defaults = Fixtures.isolatedDefaults()
        let transport = TestTransport()
        transport.automaticResponse = { Fixtures.response(for: $0, snapshot: Fixtures.snapshot(accent: "purple")) }
        let model = WatchCompanionModel(
            client: WatchRequestClient(transport: transport, waitForDeadline: neverDeadline),
            accentStore: WatchAccentStore(defaults: defaults), heartbeatInterval: .seconds(3_600)
        )
        #expect(model.accent == .orange)
        model.setForeground(true)
        try await waitUntil { model.accent == .purple }
        #expect(defaults.string(forKey: WatchAccentStore.key) == "purple")
        model.setForeground(false)
    }
}
