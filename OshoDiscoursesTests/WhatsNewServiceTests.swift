import Foundation
import Testing
@testable import OshoDiscourses

@MainActor
struct WhatsNewServiceTests {
    private let releases: [AppRelease] = [
        AppRelease(version: "1.18.0", items: ["Not shipped in this build"], highlights: nil),
        AppRelease(version: "1.17.0", items: ["Translation"], highlights: [.init(symbol: "globe", title: "Listen", detail: "In Hindi")]),
        AppRelease(version: "1.16.3", items: ["Speed"], highlights: nil),
        AppRelease(version: "1.16.2", items: ["Copy"], highlights: nil),
        AppRelease(version: "1.10.0", items: ["Boost"], highlights: nil),
        AppRelease(version: "1.9", items: ["Mirror"], highlights: nil),
    ]

    @Test func versionsCompareByNumberNotText() {
        #expect(ReleaseNotes.compare("1.10.0", "1.9.1") == .orderedDescending)
        #expect(ReleaseNotes.compare("1.9", "1.9.0") == .orderedSame)
        #expect(ReleaseNotes.compare("1.16.3", "1.17") == .orderedAscending)
    }

    @Test func contentShowsTheInstalledReleaseAndWhatWasSkippedButNeverNewerOnes() throws {
        let content = try #require(WhatsNewContent.make(installed: "1.17.0", lastSeen: "1.16.2", releases: releases))
        #expect(content.current.version == "1.17.0")
        #expect(content.sinceLastSeen.map(\.version) == ["1.16.3"])
        #expect(content.earlier.map(\.version) == ["1.16.2", "1.10.0", "1.9"])
        let history = try #require(WhatsNewContent.make(installed: "1.17.0", lastSeen: nil, releases: releases))
        #expect(history.sinceLastSeen.isEmpty)
        #expect(history.earlier.count == 4)
        #expect(WhatsNewContent.make(installed: "1.17.1", lastSeen: nil, releases: releases) == nil)
    }

    @Test func anUpdateShowsOnceAndOnlyInOneWindow() throws {
        try withDefaults { defaults in
            defaults.set("1.16.2", forKey: WhatsNewService.lastSeenKey)
            let service = WhatsNewService(defaults: defaults, installedVersion: "1.17.0", releases: releases)
            let first = UUID(), second = UUID()
            #expect(service.claimPresentation(owner: first))
            #expect(service.claimPresentation(owner: first))
            #expect(!service.claimPresentation(owner: second))
            #expect(defaults.string(forKey: WhatsNewService.lastSeenKey) == "1.16.2")
            service.finishPresentation(owner: second)
            #expect(service.presentingOwner == first)
            service.finishPresentation(owner: first)
            #expect(defaults.string(forKey: WhatsNewService.lastSeenKey) == "1.17.0")
            #expect(!service.claimPresentation(owner: second))
            // Skipped releases stay listed for this launch after the update is marked seen.
            #expect(service.updateContent?.sinceLastSeen.map(\.version) == ["1.16.3"])
            let relaunched = WhatsNewService(defaults: defaults, installedVersion: "1.17.0", releases: releases)
            #expect(!relaunched.claimPresentation(owner: UUID()))
        }
    }

    @Test func theAnnouncementStaysDueUntilSeenSoOtherWindowsKeepWaiting() throws {
        try withDefaults { defaults in
            defaults.set("1.16.3", forKey: WhatsNewService.lastSeenKey)
            let service = WhatsNewService(defaults: defaults, installedVersion: "1.17.0", releases: releases)
            let owner = UUID()
            #expect(service.isAnnouncementDue)
            #expect(service.claimPresentation(owner: owner))
            #expect(service.isAnnouncementDue)
            service.finishPresentation(owner: owner)
            #expect(!service.isAnnouncementDue)
            let fresh = WhatsNewService(defaults: UserDefaults(suiteName: "WhatsNewFresh.\(UUID().uuidString)")!,
                                        installedVersion: "1.17.0", releases: releases, hasPriorUse: { false })
            #expect(!fresh.isAnnouncementDue)
        }
    }

    @Test func aFreshInstallIsRecordedBeforeAnyWindowIsReadySoLaterUseIsNotAnUpdate() throws {
        try withDefaults { defaults in
            var used = false
            let launch = WhatsNewService(defaults: defaults, installedVersion: "1.17.0", releases: releases, hasPriorUse: { used })
            launch.recordFreshInstallIfNeeded()
            #expect(defaults.string(forKey: WhatsNewService.lastSeenKey) == "1.17.0")
            used = true
            let nextLaunch = WhatsNewService(defaults: defaults, installedVersion: "1.17.0", releases: releases, hasPriorUse: { used })
            nextLaunch.recordFreshInstallIfNeeded()
            #expect(!nextLaunch.isAnnouncementDue)
            #expect(!nextLaunch.claimPresentation(owner: UUID()))
            let existing = try #require(UserDefaults(suiteName: "WhatsNewExisting.\(UUID().uuidString)"))
            let upgrade = WhatsNewService(defaults: existing, installedVersion: "1.17.0", releases: releases, hasPriorUse: { true })
            upgrade.recordFreshInstallIfNeeded()
            #expect(existing.string(forKey: WhatsNewService.lastSeenKey) == nil)
            #expect(upgrade.isAnnouncementDue)
        }
    }

    @Test func aFreshInstallIsMarkedSeenWithoutShowing() throws {
        try withDefaults { defaults in
            let service = WhatsNewService(defaults: defaults, installedVersion: "1.17.0", releases: releases, hasPriorUse: { false })
            #expect(!service.claimPresentation(owner: UUID()))
            #expect(defaults.string(forKey: WhatsNewService.lastSeenKey) == "1.17.0")
        }
    }

    @Test func registeredSettingsDoNotCountAsUseButListeningDoes() throws {
        try withDefaults { defaults in
            defaults.register(defaults: ["settings.defaultPlaybackRate": 1.0, "settings.languageFilter": "Both"])
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("WhatsNew-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: file) }
            #expect(!WhatsNewService.hasPriorUse(in: defaults, files: [file]))
            try Data("{}".utf8).write(to: file)
            #expect(WhatsNewService.hasPriorUse(in: defaults, files: [file]))
            try FileManager.default.removeItem(at: file)
            defaults.set(["english-A_Bird_on_the_Wing__-1"], forKey: "allPlayedDiscourseIDs")
            #expect(WhatsNewService.hasPriorUse(in: defaults, files: [file]))
        }
    }

    @Test func aClosedWindowGivesTheClaimBackWithoutMarkingItSeen() throws {
        try withDefaults { defaults in
            defaults.set("1.16.2", forKey: WhatsNewService.lastSeenKey)
            let service = WhatsNewService(defaults: defaults, installedVersion: "1.17.0", releases: releases)
            let closed = UUID(), other = UUID()
            #expect(service.claimPresentation(owner: closed))
            service.abandonPresentation(owner: other)
            #expect(service.presentingOwner == closed)
            service.abandonPresentation(owner: closed)
            #expect(defaults.string(forKey: WhatsNewService.lastSeenKey) == "1.16.2")
            #expect(service.claimPresentation(owner: other))
        }
    }

    @Test func listenersFromBeforeThisScreenSeeItOnTheirFirstUpdate() throws {
        try withDefaults { defaults in
            defaults.set(["english-A_Bird_on_the_Wing__-1"], forKey: "recentlyPlayed")
            let service = WhatsNewService(defaults: defaults, installedVersion: "1.17.0", releases: releases)
            #expect(service.claimPresentation(owner: UUID()))
            // Without a last-seen version there is no "since your last update" to list.
            #expect(service.updateContent?.sinceLastSeen.isEmpty == true)
            #expect(service.updateContent?.earlier.count == 4)
        }
    }

    @Test func aVersionWithoutNotesIsSkippedAndAnOlderBuildNeverReannounces() throws {
        try withDefaults { defaults in
            defaults.set("1.16.3", forKey: WhatsNewService.lastSeenKey)
            let unknown = WhatsNewService(defaults: defaults, installedVersion: "1.17.5", releases: releases)
            #expect(!unknown.claimPresentation(owner: UUID()))
            #expect(defaults.string(forKey: WhatsNewService.lastSeenKey) == "1.17.5")
            let downgraded = WhatsNewService(defaults: defaults, installedVersion: "1.17.0", releases: releases)
            #expect(!downgraded.claimPresentation(owner: UUID()))
        }
    }

    @Test func shippedNotesAreNewestFirstAndCoverEveryRelease() throws {
        let shipped = ReleaseNotes.all
        #expect(!shipped.isEmpty)
        #expect(zip(shipped, shipped.dropFirst()).allSatisfy { ReleaseNotes.compare($0.version, $1.version) == .orderedDescending })
        #expect(shipped.allSatisfy { !$0.items.isEmpty && $0.items.allSatisfy { !$0.isEmpty } })
        #expect(shipped.contains { $0.version == "1.0" })
        let installed = WhatsNewService.bundleVersion
        #expect(WhatsNewContent.make(installed: installed, lastSeen: nil, releases: shipped) != nil, "Notes are missing for \(installed)")
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "WhatsNewServiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
}
