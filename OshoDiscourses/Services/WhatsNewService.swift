import Foundation
import Observation
import os

/// One App Store release as listeners saw it, newest first in `ReleaseNotes.json`.
struct AppRelease: Decodable, Equatable, Identifiable, Sendable {
    struct Highlight: Decodable, Equatable, Hashable, Sendable {
        let symbol: String
        let title: String
        let detail: String
    }

    let version: String
    let items: [String]
    /// Hand-written headline features; releases without them show their items.
    let highlights: [Highlight]?

    var id: String { version }
}

enum ReleaseNotes {
    private struct File: Decodable { let releases: [AppRelease] }

    /// Built by scripts/build-release-notes.py from App Store Connect.
    static let all: [AppRelease] = {
        guard let url = Bundle.main.url(forResource: "ReleaseNotes", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return decode(data)
    }()

    static func decode(_ data: Data) -> [AppRelease] {
        let releases = (try? JSONDecoder().decode(File.self, from: data).releases) ?? []
        return releases.sorted { compare($0.version, $1.version) == .orderedDescending }
    }

    /// Numeric by component, so 1.10.0 is newer than 1.9.1 and 1.9 equals 1.9.0.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

/// What the What's New screen shows for one installed version.
struct WhatsNewContent: Equatable, Sendable {
    /// The installed version's release.
    let current: AppRelease
    /// Releases the listener skipped since the version they last saw, newest first.
    let sinceLastSeen: [AppRelease]
    /// Everything older still, for the Earlier Updates list.
    let earlier: [AppRelease]

    /// Releases newer than the installed app are never shown; they describe features it lacks.
    static func make(installed: String, lastSeen: String?, releases: [AppRelease]) -> WhatsNewContent? {
        let available = releases.filter { ReleaseNotes.compare($0.version, installed) != .orderedDescending }
        guard let current = available.first(where: { ReleaseNotes.compare($0.version, installed) == .orderedSame }) else {
            return nil
        }
        let older = available.filter { ReleaseNotes.compare($0.version, installed) == .orderedAscending }
        let skipped = lastSeen.map { seen in older.filter { ReleaseNotes.compare($0.version, seen) == .orderedDescending } } ?? []
        let skippedIDs = Set(skipped.map(\.id))
        return WhatsNewContent(current: current, sinceLastSeen: skipped, earlier: older.filter { !skippedIDs.contains($0.id) })
    }
}

/// Shows What's New once per update, in one window, and never to someone who just installed the app.
@Observable
@MainActor
final class WhatsNewService {
    static let shared = WhatsNewService(defaults: .standard, installedVersion: WhatsNewService.bundleVersion)

    static let lastSeenKey = "whatsNew.lastSeenVersion"
    private static let log = Logger(subsystem: "com.agraabhi.oshodiscourses", category: "WhatsNew")

    /// Keys written only by use, never registered as defaults: `object(forKey:)` also returns
    /// registered values, so a registered setting would make every fresh install look used.
    static let usageKeys = [
        "recentlyPlayed", "allPlayedDiscourseIDs", "completedDiscourseIDs", "listenedCompletedIDs",
        "review.lastPromptedVersion",
    ]

    /// Files written only after listening or bookmarking.
    static var usageFiles: [URL] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return [support.appendingPathComponent("listening_stats.json"), documents.appendingPathComponent("bookmarks.json")]
    }

    static func hasPriorUse(in defaults: UserDefaults, files: [URL]) -> Bool {
        usageKeys.contains { defaults.object(forKey: $0) != nil }
            || files.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    private(set) var presentingOwner: UUID?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let installedVersion: String
    @ObservationIgnored private let releases: [AppRelease]
    @ObservationIgnored private let hasPriorUse: () -> Bool
    /// The version seen before this launch; kept so the screen can list skipped releases after it is marked seen.
    @ObservationIgnored private let previouslySeen: String?
    /// Saved defaults can be masked (launch arguments) or fail to write; this launch never repeats it.
    @ObservationIgnored private var finishedThisLaunch = false

    init(
        defaults: UserDefaults, installedVersion: String, releases: [AppRelease] = ReleaseNotes.all,
        hasPriorUse: (() -> Bool)? = nil
    ) {
        self.defaults = defaults
        self.installedVersion = installedVersion
        self.releases = releases
        self.hasPriorUse = hasPriorUse ?? { Self.hasPriorUse(in: defaults, files: Self.usageFiles) }
        previouslySeen = defaults.string(forKey: Self.lastSeenKey)
    }

    static var bundleVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// The screen's content after an update, including releases skipped since the last one seen.
    var updateContent: WhatsNewContent? {
        WhatsNewContent.make(installed: installedVersion, lastSeen: previouslySeen, releases: releases)
    }

    /// The full history, for Settings.
    var historyContent: WhatsNewContent? {
        WhatsNewContent.make(installed: installedVersion, lastSeen: nil, releases: releases)
    }

    /// Records a fresh install at launch, before any window is ready, so later use in this build
    /// is never mistaken for an update.
    func recordFreshInstallIfNeeded() {
        guard defaults.string(forKey: Self.lastSeenKey) == nil, !hasPriorUse() else { return }
        defaults.set(installedVersion, forKey: Self.lastSeenKey)
        Self.log.info("outcome=fresh_install")
    }

    /// Still waiting to be shown: an update with notes that this listener has not seen.
    var isAnnouncementDue: Bool {
        guard !finishedThisLaunch, updateContent != nil else { return false }
        if let seen = defaults.string(forKey: Self.lastSeenKey) {
            return ReleaseNotes.compare(seen, installedVersion) == .orderedAscending
        }
        return hasPriorUse()
    }

    /// Claims the one-time presentation for this window. A fresh install is marked seen without showing.
    func claimPresentation(owner: UUID) -> Bool {
        if let presentingOwner { return presentingOwner == owner }
        guard !finishedThisLaunch else { return false }
        let seen = defaults.string(forKey: Self.lastSeenKey)
        guard seen.map({ ReleaseNotes.compare($0, installedVersion) == .orderedAscending }) ?? hasPriorUse() else {
            if seen == nil {
                defaults.set(installedVersion, forKey: Self.lastSeenKey)
                Self.log.info("outcome=fresh_install")
            }
            return false
        }
        guard updateContent != nil else {
            // No notes for this version, so there is nothing to announce.
            defaults.set(installedVersion, forKey: Self.lastSeenKey)
            Self.log.notice("outcome=no_notes")
            return false
        }
        presentingOwner = owner
        Self.log.info("outcome=presented")
        return true
    }

    /// A window that closes while showing the screen gives the claim back without marking it seen.
    func abandonPresentation(owner: UUID) {
        guard presentingOwner == owner else { return }
        presentingOwner = nil
        Self.log.notice("outcome=abandoned")
    }

    /// Marked seen when the screen closes, so a launch interrupted before it appears tries again.
    func finishPresentation(owner: UUID) {
        guard presentingOwner == owner else { return }
        presentingOwner = nil
        finishedThisLaunch = true
        defaults.set(installedVersion, forKey: Self.lastSeenKey)
        Self.log.info("outcome=dismissed")
    }
}
