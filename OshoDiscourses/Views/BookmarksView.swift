import SwiftUI

struct BookmarksView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(DownloadService.self) private var downloads
    private var bookmarkService = BookmarkService.shared
    @State private var filterCategory: BookmarkCategory? = nil

    private var displayedBookmarks: [Bookmark] {
        if let cat = filterCategory {
            return bookmarkService.bookmarks.filter { $0.category == cat }
        }
        return bookmarkService.bookmarks
    }

    private var groupedBookmarks: [(series: String, bookmarks: [Bookmark])] {
        let grouped = Dictionary(grouping: displayedBookmarks) { $0.seriesName }
        return grouped
            .map { (series: $0.key, bookmarks: $0.value.sorted { $0.createdAt > $1.createdAt }) }
            .sorted { $0.series < $1.series }
    }

    var body: some View {
        NavigationStack {
            Group {
                if bookmarkService.bookmarks.isEmpty {
                    ContentUnavailableView(
                        "No Bookmarks",
                        systemImage: "bookmark",
                        description: Text("Tap the bookmark icon in the player to save a moment.")
                    )
                } else {
                    VStack(spacing: 0) {
                        categoryFilterBar
                        bookmarkList
                    }
                }
            }
            .background(Color(.systemBackground))
            .navigationTitle("Bookmarks")
        }
    }

    private var categoryFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(label: "All", icon: "bookmark.fill", isActive: filterCategory == nil) {
                    filterCategory = nil
                }

                ForEach(BookmarkCategory.allCases) { category in
                    FilterChip(
                        label: category.rawValue,
                        icon: category.icon,
                        isActive: filterCategory == category
                    ) {
                        filterCategory = filterCategory == category ? nil : category
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
    }

    private var bookmarkList: some View {
        List {
            if displayedBookmarks.isEmpty {
                ContentUnavailableView(
                    "No bookmarks in this category",
                    systemImage: "bookmark.slash",
                    description: Text("Try a different filter.")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(groupedBookmarks, id: \.series) { group in
                    Section(group.series) {
                        ForEach(group.bookmarks) { bookmark in
                            BookmarkRow(bookmark: bookmark)
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                bookmarkService.remove(id: group.bookmarks[index].id)
                            }
                        }
                    }
                    .listRowBackground(Color(.secondarySystemGroupedBackground))
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }
}

private struct FilterChip: View {
    let label: String
    let icon: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption2)
                Text(label)
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isActive ? Color.blue : Color(.tertiarySystemFill))
            .foregroundStyle(isActive ? .white : .primary)
            .clipShape(Capsule())
        }
    }
}

private struct BookmarkRow: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(DownloadService.self) private var downloads
    let bookmark: Bookmark

    private var isPlaying: Bool {
        player.currentTrackId == bookmark.discourseID && player.isPlaying
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(bookmark.title)
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundStyle(isPlaying ? .blue : .primary)

                HStack(spacing: 6) {
                    // Category tag
                    HStack(spacing: 3) {
                        Image(systemName: bookmark.category.icon)
                            .font(.system(size: 9))
                        Text(bookmark.displayCategory)
                            .font(.caption2)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.12))
                    .foregroundStyle(.blue)
                    .clipShape(Capsule())

                    // Timestamp
                    Text(bookmark.formattedTimestamp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                if !bookmark.note.isEmpty {
                    Text(bookmark.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            if downloads.isDownloaded(bookmark.discourseID) {
                Button {
                    playBookmark()
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            } else if downloads.isDownloading(bookmark.discourseID) {
                ProgressView()
                    .frame(width: 28, height: 28)
            } else {
                Button {
                    redownload()
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.title2)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    private func playBookmark() {
        guard let url = downloads.localFileURL(for: bookmark.discourseID) else { return }

        if player.currentTrackId == bookmark.discourseID {
            player.seekWithHistory(to: bookmark.timestamp)
        } else {
            player.play(
                localURL: url,
                id: bookmark.discourseID,
                title: bookmark.title,
                series: bookmark.seriesName
            )
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                player.seekWithHistory(to: bookmark.timestamp)
            }
        }
    }

    private func redownload() {
        guard let discourse = findCatalogDiscourse() else { return }
        Task {
            _ = try? await downloads.download(discourse)
        }
    }

    private func findCatalogDiscourse() -> CatalogDiscourse? {
        for series in Catalog.allSeries {
            let discourses = Catalog.discourses(for: series)
            if let match = discourses.first(where: { $0.id == bookmark.discourseID }) {
                return match
            }
        }
        return nil
    }
}
