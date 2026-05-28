import SwiftUI

struct DownloadsView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(DownloadService.self) private var downloads
    @Bindable private var settings = UserSettings.shared

    private var groupedDownloads: [(seriesInfo: SeriesInfo, discourses: [CatalogDiscourse])] {
        downloads.downloadedDiscourses()
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: $settings.smartDownload) {
                        Label("Smart Download", systemImage: "arrow.down.circle")
                    }
                    Toggle(isOn: $settings.smartDelete) {
                        Label("Smart Delete", systemImage: "trash.circle")
                    }
                }
                .listRowBackground(Color(.secondarySystemGroupedBackground))

                if groupedDownloads.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No Downloads",
                            systemImage: "arrow.down.circle",
                            description: Text("Downloaded discourses will appear here.")
                        )
                    }
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(groupedDownloads, id: \.seriesInfo.id) { group in
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
                            DownloadedSeriesHeader(
                                seriesInfo: group.seriesInfo,
                                count: group.discourses.count
                            )
                        }
                        .listRowBackground(Color(.secondarySystemGroupedBackground))
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color(.systemBackground))
            .navigationTitle("Downloads")
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
                    .foregroundStyle(.white)

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
                .foregroundStyle(isCurrentlyPlaying ? .blue : .primary)

            Spacer()

            Button {
                playDiscourse()
            } label: {
                Image(systemName: isCurrentlyPlaying && player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            playDiscourse()
        }
    }

    private func playDiscourse() {
        guard let url = downloads.localFileURL(for: discourse.id) else { return }

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
