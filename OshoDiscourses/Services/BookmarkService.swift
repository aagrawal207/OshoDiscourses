import Foundation
import Observation

enum BookmarkCategory: String, Codable, CaseIterable, Identifiable {
    case relisten = "Re-listen"
    case funny = "Funny"
    case awesome = "Awesome"
    case profound = "Profound"
    case meditation = "Meditation"
    case custom = "Custom"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .relisten: return "arrow.counterclockwise"
        case .funny: return "face.smiling"
        case .awesome: return "star.fill"
        case .profound: return "brain.head.profile"
        case .meditation: return "figure.mind.and.body"
        case .custom: return "tag"
        }
    }
}

struct Bookmark: Codable, Identifiable, Hashable {
    let id: String
    let discourseID: String
    let seriesName: String
    let title: String
    let timestamp: TimeInterval
    let note: String
    let category: BookmarkCategory
    let customCategory: String?
    let createdAt: Date

    init(
        discourseID: String,
        seriesName: String,
        title: String,
        timestamp: TimeInterval,
        note: String = "",
        category: BookmarkCategory = .relisten,
        customCategory: String? = nil
    ) {
        self.id = UUID().uuidString
        self.discourseID = discourseID
        self.seriesName = seriesName
        self.title = title
        self.timestamp = timestamp
        self.note = note
        self.category = category
        self.customCategory = customCategory
        self.createdAt = Date()
    }

    var formattedTimestamp: String {
        let total = Int(timestamp)
        let hrs = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        if hrs > 0 {
            return String(format: "%d:%02d:%02d", hrs, mins, secs)
        }
        return String(format: "%d:%02d", mins, secs)
    }

    var displayCategory: String {
        if category == .custom, let custom = customCategory, !custom.isEmpty {
            return custom
        }
        return category.rawValue
    }
}

@Observable
@MainActor
final class BookmarkService {
    static let shared = BookmarkService()

    private(set) var bookmarks: [Bookmark] = []

    /// Tombstones for deleted bookmarks, so a delete sticks across devices and
    /// relaunches instead of resurrecting from a stale cloud snapshot (union-
    /// by-id alone can't distinguish "deleted here" from "added there").
    /// Bookmark ids are UUIDs minted once at creation, so a tombstone can never
    /// collide with a future add. Persisted in UserDefaults (tiny), synced via
    /// the cloud snapshot (union-merged), capped to the newest entries.
    private(set) var deletedBookmarkIDs: [String] = []
    private let tombstonesKey = "deletedBookmarkIDs"
    private static let maxTombstones = 500

    /// Called after the local bookmark set is persisted (add/remove) so iCloud
    /// sync can push. Set by the app on startup; nil keeps sync inert. Not fired
    /// by `mergeSyncedBookmarks` — that's already reconciling cloud data.
    var onBookmarksChanged: (() -> Void)?

    private let fileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("bookmarks.json")
    }()

    private init() {
        deletedBookmarkIDs = UserDefaults.standard.stringArray(forKey: tombstonesKey) ?? []
        load()
    }

    func add(
        discourseID: String,
        seriesName: String,
        title: String,
        timestamp: TimeInterval,
        note: String = "",
        category: BookmarkCategory = .relisten,
        customCategory: String? = nil
    ) {
        let bookmark = Bookmark(
            discourseID: discourseID,
            seriesName: seriesName,
            title: title,
            timestamp: timestamp,
            note: note,
            category: category,
            customCategory: customCategory
        )
        bookmarks.insert(bookmark, at: 0)
        save()
        onBookmarksChanged?()
    }

    func remove(id: String) {
        bookmarks.removeAll { $0.id == id }
        recordTombstone(id)
        save()
        onBookmarksChanged?()
    }

    private func recordTombstone(_ id: String) {
        deletedBookmarkIDs.removeAll { $0 == id }
        deletedBookmarkIDs.append(id)
        if deletedBookmarkIDs.count > Self.maxTombstones {
            deletedBookmarkIDs = Array(deletedBookmarkIDs.suffix(Self.maxTombstones))
        }
        UserDefaults.standard.set(deletedBookmarkIDs, forKey: tombstonesKey)
    }

    func bookmarks(for discourseID: String) -> [Bookmark] {
        bookmarks.filter { $0.discourseID == discourseID }
    }

    // MARK: - iCloud Sync

    /// Merge bookmarks arriving from another device. Union by stable `id`, newest
    /// first by `createdAt`, minus anything either side has deleted — so adds
    /// converge regardless of write order, and deletes stick instead of
    /// resurrecting from a device (or a stale cloud snapshot) that still has
    /// the bookmark. Returns true if the local set changed.
    @discardableResult
    func mergeSyncedBookmarks(_ incoming: [Bookmark], deletedIDs: [String] = []) -> Bool {
        // Tombstones union-merge first (monotonic, order-independent).
        let mergedTombstones = Self.mergeList(local: deletedBookmarkIDs, incoming: deletedIDs, cap: Self.maxTombstones)
        if mergedTombstones != deletedBookmarkIDs {
            deletedBookmarkIDs = mergedTombstones
            UserDefaults.standard.set(deletedBookmarkIDs, forKey: tombstonesKey)
        }
        let merged = Self.mergeBookmarks(local: bookmarks, incoming: incoming, deleted: Set(deletedBookmarkIDs))
        guard merged != bookmarks else { return false }
        bookmarks = merged
        save()
        return true
    }

    /// Pure union-by-id merge, sorted newest-first, with deleted ids filtered
    /// out. Local entries win on id collisions (they're identical anyway since
    /// id is a UUID minted at creation).
    static func mergeBookmarks(local: [Bookmark], incoming: [Bookmark], deleted: Set<String> = []) -> [Bookmark] {
        var byID: [String: Bookmark] = [:]
        for b in incoming where !deleted.contains(b.id) { byID[b.id] = b }
        for b in local where !deleted.contains(b.id) { byID[b.id] = b }   // local overrides on collision
        return byID.values.sorted { $0.createdAt > $1.createdAt }
    }

    /// Ordered union of two id lists, deduped (keeping the later occurrence's
    /// position stable enough for a cap that trims the *oldest* entries).
    static func mergeList(local: [String], incoming: [String], cap: Int) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for id in local + incoming where !seen.contains(id) {
            seen.insert(id)
            result.append(id)
        }
        return Array(result.suffix(cap))
    }

    func bookmarks(forCategory category: BookmarkCategory) -> [Bookmark] {
        bookmarks.filter { $0.category == category }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        // Atomic: write to a temp file then rename, so a crash mid-write can't
        // leave a truncated bookmarks.json. Bookmarks are user-authored and can't
        // be recomputed — a torn write here is permanent data loss. (listening_stats
        // already writes atomically; this brings bookmarks in line.)
        try? data.write(to: fileURL, options: .atomic)
    }

    private func load() {
        // Missing file = first launch, nothing to load. Only treat a genuine
        // *decode* failure as corruption.
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            bookmarks = try JSONDecoder().decode([Bookmark].self, from: data)
        } catch {
            // The file exists but won't decode (truncated/corrupt). Preserve it as
            // .bak instead of letting the next save() overwrite it empty, so the
            // data can be recovered manually rather than silently lost forever.
            let backupURL = fileURL.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.moveItem(at: fileURL, to: backupURL)
            print("[Bookmarks] failed to decode bookmarks.json; preserved as \(backupURL.lastPathComponent): \(error)")
        }
    }
}
