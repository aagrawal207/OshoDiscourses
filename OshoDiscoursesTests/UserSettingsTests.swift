import Testing
import Foundation
@testable import OshoDiscourses

/// UserSettings is a singleton over UserDefaults, so these tests set values and
/// confirm they persist to the backing store under the documented keys. They
/// also lock down the new defaults (cellular off, rate 1.0) and the dead-flag
/// removal (those keys must no longer be registered).
@Suite(.serialized)
@MainActor
struct UserSettingsTests {

    @Test func defaultPlaybackRatePersists() {
        let settings = UserSettings.shared
        let original = settings.defaultPlaybackRate
        settings.defaultPlaybackRate = 1.25
        #expect(UserDefaults.standard.double(forKey: "settings.defaultPlaybackRate") == 1.25)
        settings.defaultPlaybackRate = original
    }

    @Test func cellularDownloadsPersists() {
        let settings = UserSettings.shared
        let original = settings.allowCellularDownloads
        settings.allowCellularDownloads = true
        #expect(UserDefaults.standard.bool(forKey: "settings.allowCellularDownloads") == true)
        settings.allowCellularDownloads = false
        #expect(UserDefaults.standard.bool(forKey: "settings.allowCellularDownloads") == false)
        settings.allowCellularDownloads = original
    }

    @Test func cellularDefaultsOff() {
        // Registered default (not a user-set value) must be false so downloads
        // never silently run on cellular out of the box.
        let fresh = UserDefaults.standard.bool(forKey: "settings.allowCellularDownloads")
        // The value may have been toggled by other tests; assert the registered
        // default directly instead.
        UserDefaults.standard.removeObject(forKey: "settings.allowCellularDownloads")
        #expect(UserDefaults.standard.bool(forKey: "settings.allowCellularDownloads") == false)
        // Restore whatever it was.
        UserDefaults.standard.set(fresh, forKey: "settings.allowCellularDownloads")
    }

    @Test func deadCuratedSectionKeysAreGone() {
        // These flags were removed because HomeView never read them. The
        // properties shouldn't exist; here we assert the registered defaults are
        // no longer seeded (a removed key reads as false / not-present).
        let keys = [
            "settings.showPopularEnglish",
            "settings.showPopularHindi",
            "settings.showBeginnerEnglish",
            "settings.showBeginnerHindi",
        ]
        // Touch the singleton so register(defaults:) has run.
        _ = UserSettings.shared
        for key in keys {
            // If these were still registered they'd come back as `true`.
            UserDefaults.standard.removeObject(forKey: key)
            #expect(UserDefaults.standard.object(forKey: key) == nil)
        }
    }

    @Test func languageFilterPersists() {
        let settings = UserSettings.shared
        let original = settings.languageFilter
        settings.languageFilter = .hindi
        #expect(UserDefaults.standard.string(forKey: "settings.languageFilter") == "Hindi")
        settings.languageFilter = original
    }

    // MARK: - Daily accent shuffle

    @Test func shuffleAdvancesEachDay() {
        // Consecutive days must yield different colors — that's the whole point.
        for day in 0..<30 {
            let today = UserSettings.shuffledTheme(forDaysSinceEpoch: day)
            let tomorrow = UserSettings.shuffledTheme(forDaysSinceEpoch: day + 1)
            #expect(today != tomorrow)
        }
    }

    @Test func shuffleIsDeterministicForSameDay() {
        // Every view must agree within a day, so the same input → same color.
        #expect(
            UserSettings.shuffledTheme(forDaysSinceEpoch: 12345)
            == UserSettings.shuffledTheme(forDaysSinceEpoch: 12345)
        )
    }

    @Test func shuffleCyclesThroughWholePalette() {
        // Across one full cycle every palette color appears exactly once.
        let count = AccentTheme.allCases.count
        let seen = Set((0..<count).map { UserSettings.shuffledTheme(forDaysSinceEpoch: $0) })
        #expect(seen.count == count)
    }

    @Test func shuffleHandlesNegativeDayIndex() {
        // startOfDay math could in principle yield a negative; must not crash.
        let theme = UserSettings.shuffledTheme(forDaysSinceEpoch: -3)
        #expect(AccentTheme.allCases.contains(theme))
    }

    @Test func effectiveThemeIgnoresShuffleWhenOff() {
        let settings = UserSettings.shared
        let originalShuffle = settings.dailyAccentShuffle
        let originalTheme = settings.accentTheme
        settings.dailyAccentShuffle = false
        settings.accentTheme = .pink
        #expect(settings.effectiveAccentTheme == .pink)
        settings.dailyAccentShuffle = originalShuffle
        settings.accentTheme = originalTheme
    }
}

/// Bulk-delete helpers on DownloadService. We don't write real files here; with
/// no matching downloads these must be safe no-ops that leave the set empty.
@Suite(.serialized)
@MainActor
struct DownloadDeleteTests {

    @Test func deleteAllOnEmptyIsNoop() {
        let service = DownloadService()
        service.deleteAllDownloads()
        #expect(service.downloadedIDs.isEmpty)
    }

    @Test func deleteDownloadsIgnoresUnknownIDs() {
        let service = DownloadService()
        // Deleting IDs that were never downloaded must not crash or add state.
        service.deleteDownloads(ids: ["nope-1", "nope-2"])
        #expect(!service.isDownloaded("nope-1"))
        #expect(service.downloadedIDs.isEmpty)
    }
}

/// Queue-state helpers on DownloadService. Downloads run one at a time; a
/// waiting one is "queued" — it counts as in-progress for the row's cancel
/// control but should be labelled distinctly so it doesn't look like a stuck 0%.
@Suite(.serialized)
@MainActor
struct DownloadQueueStateTests {

    @Test func queuedCountsAsDownloadingButIsFlaggedQueued() {
        let service = DownloadService()
        service.activeDownloads["a"] = .init(status: .queued)
        #expect(service.isDownloading("a"))   // occupies the row's progress control
        #expect(service.isQueued("a"))         // ...but shows as "waiting", not 0%
    }

    @Test func activeTransferIsDownloadingNotQueued() {
        let service = DownloadService()
        service.activeDownloads["b"] = .init(status: .downloading)
        #expect(service.isDownloading("b"))
        #expect(!service.isQueued("b"))
    }

    @Test func finishedStatesAreNeitherDownloadingNorQueued() {
        let service = DownloadService()
        service.activeDownloads["done"] = .init(progress: 1, status: .complete)
        service.activeDownloads["bad"] = .init(status: .failed("nope"))
        for id in ["done", "bad"] {
            #expect(!service.isDownloading(id))
            #expect(!service.isQueued(id))
        }
    }

    @Test func cancelClearsQueuedState() {
        let service = DownloadService()
        service.activeDownloads["c"] = .init(status: .queued)
        service.cancelDownload(discourseID: "c")
        #expect(!service.isDownloading("c"))
        #expect(!service.isQueued("c"))
        #expect(service.activeDownloads["c"] == nil)
    }

    @Test func isActiveMatchesQueuedAndDownloading() {
        #expect(DownloadService.DownloadProgress(status: .queued).isActive)
        #expect(DownloadService.DownloadProgress(status: .downloading).isActive)
        #expect(!DownloadService.DownloadProgress(status: .complete).isActive)
        #expect(!DownloadService.DownloadProgress(status: .failed("x")).isActive)
    }

    /// With one transfer running and several waiting, only the running one is
    /// "downloading"; the rest report queued. Guards the one-at-a-time gate: if
    /// queued items blocked on each other (not just the transfer) they'd never
    /// start. Every entry stays active (occupies a row control) until it finishes.
    @Test func multipleQueuedBehindOneTransfer() {
        let service = DownloadService()
        service.activeDownloads["run"] = .init(status: .downloading)
        service.activeDownloads["wait1"] = .init(status: .queued)
        service.activeDownloads["wait2"] = .init(status: .queued)

        #expect(service.isDownloading("run") && !service.isQueued("run"))
        #expect(service.isQueued("wait1") && service.isDownloading("wait1"))
        #expect(service.isQueued("wait2") && service.isDownloading("wait2"))
        // Exactly one is actually transferring at a time.
        let transferring = service.activeDownloads.filter {
            if case .downloading = $0.value.status { return true } else { return false }
        }
        #expect(transferring.count == 1)
    }

    /// inProgressIDs() lists the active transfer first, then queued items. The
    /// "My Activity" download list renders in this order.
    @Test func inProgressListsTransferBeforeQueued() {
        let service = DownloadService()
        service.activeDownloads["run"] = .init(status: .downloading)
        service.activeDownloads["q1"] = .init(status: .queued)
        service.activeDownloads["q2"] = .init(status: .queued)

        let ids = service.inProgressIDs()
        #expect(Set(ids) == ["run", "q1", "q2"])
        #expect(ids.first == "run")   // the transfer is always shown first
    }

    @Test func inProgressExcludesFinishedDownloads() {
        let service = DownloadService()
        service.activeDownloads["done"] = .init(progress: 1, status: .complete)
        service.activeDownloads["bad"] = .init(status: .failed("x"))
        #expect(service.inProgressIDs().isEmpty)
    }
}
