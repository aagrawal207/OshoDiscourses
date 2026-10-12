import Foundation
import Testing
@testable import OshoDiscourses

struct DownloadSourcePolicyTests {
    @Test(arguments: [
        ("IN", "America/New_York", true),
        ("US", "Asia/Kolkata", true),
        ("US", "Asia/Calcutta", true),
        (nil, "Asia/Kathmandu", true),
        ("BD", "Europe/London", true),
        ("US", "America/Los_Angeles", false),
        ("GB", "Europe/London", false),
        ("SG", "Asia/Singapore", false),
    ] as [(String?, String, Bool)])
    func indiaAndNeighboursAreNearOshoworld(region: String?, timeZone: String, near: Bool) {
        #expect(DownloadSourcePolicy.isNearOshoworld(region: region, timeZone: timeZone) == near)
    }

    @Test func nearListenersTryOshoworldFirstAndOthersTheMirror() {
        let both: [DownloadSource] = [.archive, .oshoworld]
        #expect(DownloadSourcePolicy.order(both, speeds: [:], nearOshoworld: true) == [.oshoworld, .archive])
        #expect(DownloadSourcePolicy.order(both, speeds: [:], nearOshoworld: false) == [.archive, .oshoworld])
        #expect(DownloadSourcePolicy.order([.oshoworld], speeds: [:], nearOshoworld: false) == [.oshoworld])
        #expect(DownloadSourcePolicy.order([.archive], speeds: [:], nearOshoworld: true) == [.archive])
    }

    @Test func measuredSpeedOverridesTheRegionalGuessOnlyWhenClearlyFaster() {
        let both: [DownloadSource] = [.archive, .oshoworld]
        // A US listener whose mirror crawls switches once oshoworld proves faster.
        #expect(DownloadSourcePolicy.order(both, speeds: [.archive: 50_000, .oshoworld: 900_000], nearOshoworld: false)
            == [.oshoworld, .archive])
        #expect(DownloadSourcePolicy.order(both, speeds: [.archive: 100_000, .oshoworld: 120_000], nearOshoworld: false)
            == [.archive, .oshoworld])
        // One measurement is not a comparison.
        #expect(DownloadSourcePolicy.order(both, speeds: [.archive: 9_000_000], nearOshoworld: true)
            == [.oshoworld, .archive])
        #expect(DownloadSourcePolicy.order(both, speeds: [.archive: 0, .oshoworld: 1], nearOshoworld: true)
            == [.oshoworld, .archive])
    }

    @Test func recentDownloadsOutweighOldOnes() {
        #expect(DownloadSourcePolicy.blended(previous: nil, sample: 400) == 400)
        #expect(DownloadSourcePolicy.blended(previous: 400, sample: 0) == 200)
        #expect(DownloadSourcePolicy.blended(previous: 400, sample: .nan) == 400)
        #expect(DownloadSourcePolicy.blended(previous: nil, sample: -1) == 0)
    }

    @Test func speedsSurviveRelaunchAndIgnoreDamagedValues() throws {
        let suite = "DownloadSourcePolicyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        DownloadSourcePolicy.saveSpeeds([.archive: 1_000, .oshoworld: 2_500], to: defaults)
        #expect(DownloadSourcePolicy.loadSpeeds(from: defaults) == [.archive: 1_000, .oshoworld: 2_500])
        defaults.set(["archive": -5.0, "oshoworld": 3.0, "unknown": 9.0], forKey: DownloadSourcePolicy.speedsKey)
        #expect(DownloadSourcePolicy.loadSpeeds(from: defaults) == [.oshoworld: 3])
        defaults.set("garbage", forKey: DownloadSourcePolicy.speedsKey)
        #expect(DownloadSourcePolicy.loadSpeeds(from: defaults).isEmpty)
    }

    @Test func networkClassificationSeparatesMobileDataFromWiFi() {
        #expect(DownloadNetwork.classify(satisfied: false, wifi: true, wired: false, cellular: true) == .offline)
        #expect(DownloadNetwork.classify(satisfied: true, wifi: false, wired: false, cellular: true) == .cellularOnly)
        #expect(DownloadNetwork.classify(satisfied: true, wifi: true, wired: false, cellular: true) == .unrestricted)
        #expect(DownloadNetwork.classify(satisfied: true, wifi: false, wired: true, cellular: false) == .unrestricted)
        // A VPN or other interface without cellular is not mobile data.
        #expect(DownloadNetwork.classify(satisfied: true, wifi: false, wired: false, cellular: false) == .unrestricted)
    }

    @MainActor
    @Test func aStalledServerIsAbandonedSoonerWhenAnotherCanBeTried() {
        let now = Date()
        let stalled = now.addingTimeInterval(-DownloadService.stallThreshold)
        let moving = now.addingTimeInterval(-DownloadService.stallThreshold + 1)
        #expect(DownloadService.stallAction(lastProgress: moving, now: now, restartsSoFar: 5, maxRestarts: 1) == .none)
        #expect(DownloadService.stallAction(lastProgress: stalled, now: now, restartsSoFar: 0, maxRestarts: 1) == .restart)
        #expect(DownloadService.stallAction(lastProgress: stalled, now: now, restartsSoFar: 1, maxRestarts: 1) == .abandon)
        #expect(DownloadService.stallAction(
            lastProgress: stalled, now: now, restartsSoFar: 1, maxRestarts: DownloadService.maxStallRestarts) == .restart)
        #expect(DownloadService.shouldTryNextSource(after: DownloadService.DownloadError.stalled))
        #expect(DownloadService.DownloadError.stalled.errorDescription
            == "The download stopped responding. Check your connection and try again.")
    }
}
