import Foundation
import Observation
import OSLog

/// Main-actor view of the offline store for lists and the storage total.
@MainActor @Observable
final class OfflineLibrary {
    private(set) var entries: [OfflineEntry] = []
    private(set) var totalBytes: Int64 = 0
    private(set) var lastRejected = false

    @ObservationIgnored let store: OfflineFileStore
    /// Runs before an entry's file is removed, so a player using it can let go first.
    @ObservationIgnored var willDelete: (@MainActor (String) -> Void)?
    /// The talk the local player has loaded, playing or paused; phone progress never moves it.
    @ObservationIgnored var loadedDiscourseID: @MainActor () -> String? = { nil }
    /// Newest phone listening seen per stored talk, so a talk skipped while loaded takes it once released.
    @ObservationIgnored private var phonePositions: [String: CompanionSavedPosition] = [:]

    init(store: OfflineFileStore) {
        self.store = store
        reload()
    }

    var inventory: [String] { entries.map(\.discourseID).sorted() }

    func contains(_ discourseID: String) -> Bool {
        entries.contains { $0.discourseID == discourseID }
    }

    func entry(for discourseID: String) -> OfflineEntry? {
        entries.first { $0.discourseID == discourseID }
    }

    func reload() {
        entries = store.allEntries()
        totalBytes = store.totalBytes
    }

    func receive(_ event: WatchTransportEvent) {
        switch event {
        case .offlineFileStored:
            lastRejected = false
            reload()
        case .offlineFileRejected:
            lastRejected = true
        default:
            break
        }
    }

    func delete(_ discourseID: String) {
        willDelete?(discourseID)
        store.delete(discourseID)
        reload()
    }

    /// Local listening; returns whether the position moved and was restamped.
    @discardableResult
    func savePosition(_ discourseID: String, position: Double, duration: Double?, finished: Bool, at date: Date) -> Bool {
        let listened = store.updatePosition(discourseID, position: position, duration: duration, finished: finished, at: date)
        reload()
        return listened
    }

    /// Takes the phone's listening wherever it is newer than the Watch's. Never reported back: it came from there.
    @discardableResult
    func adoptPhonePositions(_ positions: [CompanionSavedPosition]) -> [String] {
        for saved in positions where saved.savedAt > (phonePositions[saved.discourseID]?.savedAt ?? .distantPast) {
            phonePositions[saved.discourseID] = saved
        }
        return applyPhonePositions()
    }

    /// Re-applies remembered phone listening; the player calls this whenever it loads or releases a talk.
    @discardableResult
    func applyPhonePositions() -> [String] {
        let stored = Set(store.inventory)
        phonePositions = phonePositions.filter { stored.contains($0.key) }
        guard !phonePositions.isEmpty else { return [] }
        let changed = store.adoptPhonePositions(Array(phonePositions.values), skipping: loadedDiscourseID())
        if !changed.isEmpty {
            reload()
            Logger.watchOffline.info("adopted phone progress for \(changed.count, privacy: .public) talks")
        }
        return changed
    }

    static func storageLabel(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }
}
