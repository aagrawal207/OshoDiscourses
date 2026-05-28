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
        let mins = Int(timestamp) / 60
        let secs = Int(timestamp) % 60
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
    }

    func remove(id: String) {
        bookmarks.removeAll { $0.id == id }
        save()
    }

    func bookmarks(for discourseID: String) -> [Bookmark] {
        bookmarks.filter { $0.discourseID == discourseID }
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
