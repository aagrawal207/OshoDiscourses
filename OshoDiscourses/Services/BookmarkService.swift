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

    /// Called after the local bookmark set is persisted (add/remove) so iCloud
    /// sync can push. Set by the app on startup; nil keeps sync inert. Not fired
    /// by `mergeSyncedBookmarks` — that's already reconciling cloud data.
    var onBookmarksChanged: (() -> Void)?

    private let fileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("bookmarks.json")
    }()

    private init() {
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
        save()
        onBookmarksChanged?()
    }

    func bookmarks(for discourseID: String) -> [Bookmark] {
        bookmarks.filter { $0.discourseID == discourseID }
    }

    // MARK: - iCloud Sync

    /// Merge bookmarks arriving from another device. Union by stable `id`, newest
    /// first by `createdAt`, so adds on either device converge regardless of write
    /// order. Returns true if the local set changed.
    ///
    /// Note: this syncs additions, not deletions — a bookmark deleted on one
    /// device can reappear from another that still has it. Honoring deletes would
    /// need tombstones; bookmarks are precious and few, so we err toward keeping.
    @discardableResult
    func mergeSyncedBookmarks(_ incoming: [Bookmark]) -> Bool {
        let merged = Self.mergeBookmarks(local: bookmarks, incoming: incoming)
        guard merged != bookmarks else { return false }
        bookmarks = merged
        save()
        return true
    }

    /// Pure union-by-id merge, sorted newest-first. Local entries win on id
    /// collisions (they're identical anyway since id is a UUID minted at creation).
    static func mergeBookmarks(local: [Bookmark], incoming: [Bookmark]) -> [Bookmark] {
        var byID: [String: Bookmark] = [:]
        for b in incoming { byID[b.id] = b }
        for b in local { byID[b.id] = b }   // local overrides on collision
        return byID.values.sorted { $0.createdAt > $1.createdAt }
    }

    func bookmarks(forCategory category: BookmarkCategory) -> [Bookmark] {
        bookmarks.filter { $0.category == category }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        try? data.write(to: fileURL)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Bookmark].self, from: data) else { return }
        bookmarks = decoded
    }
}
