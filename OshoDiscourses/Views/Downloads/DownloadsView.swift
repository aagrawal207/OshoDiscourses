import SwiftUI

struct DownloadsView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(DownloadService.self) private var downloads
    @Environment(PlaybackStateService.self) private var playbackState
    @Bindable private var settings = UserSettings.shared
    private var bookmarkService = BookmarkService.shared
    @State private var searchText = ""

    private var groupedDownloads: [(seriesInfo: SeriesInfo, discourses: [CatalogDiscourse])] {
        downloads.downloadedDiscourses()
    }

    private var filteredDownloads: [(seriesInfo: SeriesInfo, discourses: [CatalogDiscourse])] {
        guard !searchText.isEmpty else { return groupedDownloads }
        let query = searchText.lowercased()
        return groupedDownloads.compactMap { group in
            let matchesSeries = group.seriesInfo.name.lowercased().contains(query)
            let matchingDiscourses = group.discourses.filter {
                matchesSeries || $0.displayTitle.lowercased().contains(query)
            }
            guard !matchingDiscourses.isEmpty else { return nil }
            return (seriesInfo: group.seriesInfo, discourses: matchingDiscourses)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                activitySection
                downloadsSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color(.systemBackground))
            .navigationTitle("My Activity")
            .navigationDestination(for: SeriesInfo.self) { series in
                SeriesDetailView(seriesInfo: series)
            }
            .searchable(text: $searchText, prompt: "Search downloads")
            .safeAreaInset(edge: .bottom) {
                Spacer().frame(height: 70)
            }
        }
    }

    // MARK: - Activity Section

    private var activitySection: some View {
        Section {
            NavigationLink {
                ListeningStatsView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "chart.bar.fill")
                        .font(.title3)
                        .foregroundStyle(Color.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Listening Stats")
                            .font(.body)
                        Text(statsSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            NavigationLink {
                BookmarksView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "bookmark.fill")
                        .font(.title3)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bookmarks")
                            .font(.body)
                        if !bookmarkService.bookmarks.isEmpty {
                            Text("\(bookmarkService.bookmarks.count) saved")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

        }
        .listRowBackground(Color(.secondarySystemGroupedBackground))
    }

    private var statsSubtitle: String {
        let stats = ListeningStatsService.shared
        let total = Int(stats.totalAllTime)
        let hrs = total / 3600
        let mins = (total % 3600) / 60
        if hrs > 0 { return "\(hrs)h \(mins)m listened" }
        if mins > 0 { return "\(mins)m listened" }
        return "Start listening to track time"
    }

    // MARK: - Downloads Section

    @ViewBuilder
    private var downloadsSection: some View {
        if filteredDownloads.isEmpty {
            Section("Downloads") {
                ContentUnavailableView(
                    searchText.isEmpty ? "No Downloads" : "No Results",
                    systemImage: searchText.isEmpty ? "arrow.down.circle" : "magnifyingglass",
                    description: Text(searchText.isEmpty
                        ? "Downloaded discourses will appear here."
                        : "No downloads match \"\(searchText)\".")
                )
            }
            .listRowBackground(Color.clear)
        } else {
            ForEach(filteredDownloads, id: \.seriesInfo.id) { group in
                Section {
                    ForEach(group.discourses) { discourse in
                        DownloadedDiscourseRow(
                            discourse: discourse,
                            seriesInfo: group.seriesInfo
                        )
                    }
                    .onDelete { indexSet in
                        deleteDiscourses(at: indexSet, in: group.discourses)
                    }
                } header: {
                    NavigationLink(value: group.seriesInfo) {
                        DownloadedSeriesHeader(
                            seriesInfo: group.seriesInfo,
                            count: group.discourses.count
                        )
                    }
                }
                .listRowBackground(Color(.secondarySystemGroupedBackground))
            }
        }
    }

    private func deleteDiscourses(at offsets: IndexSet, in discourses: [CatalogDiscourse]) {
        for index in offsets {
            try? downloads.deleteDownload(discourseID: discourses[index].id)
        }
    }
}

// MARK: - Series Header

private struct DownloadedSeriesHeader: View {
    let seriesInfo: SeriesInfo
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            SeriesThumbnailView(name: seriesInfo.name, size: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(seriesInfo.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Text("\(count) episodes")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Discourse Row

private struct DownloadedDiscourseRow: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(DownloadService.self) private var downloads
    let discourse: CatalogDiscourse
    let seriesInfo: SeriesInfo

    private var isCurrentlyPlaying: Bool {
        player.currentTrackId == discourse.id
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("\(discourse.number)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            Text(discourse.displayTitle)
                .font(.body)
                .lineLimit(1)
                .foregroundStyle(isCurrentlyPlaying ? Color.accent : .primary)

            Spacer()

            Button {
                playDiscourse()
            } label: {
                Image(systemName: isCurrentlyPlaying && player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accent)
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            playDiscourse()
        }
    }

    private func playDiscourse() {
        guard downloads.localFileURL(for: discourse.id) != nil else { return }

        let allDiscourses = Catalog.discourses(for: seriesInfo)
        let queueItems = allDiscourses
            .filter { downloads.isDownloaded($0.id) }
            .compactMap { d -> AudioPlayerService.QueueItem? in
                guard let fileURL = downloads.localFileURL(for: d.id) else { return nil }
                return AudioPlayerService.QueueItem(
                    id: d.id,
                    url: fileURL,
                    title: d.displayTitle,
                    series: seriesInfo.name
                )
            }

        let startIndex = queueItems.firstIndex { $0.id == discourse.id } ?? 0
        player.playQueue(items: queueItems, startIndex: startIndex)
    }
}
