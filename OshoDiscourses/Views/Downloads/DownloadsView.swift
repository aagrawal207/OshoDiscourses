import SwiftUI

struct DownloadsView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(DownloadService.self) private var downloads
    @Environment(PlaybackStateService.self) private var playbackState
    @Bindable private var settings = UserSettings.shared
    private var bookmarkService = BookmarkService.shared
    @State private var searchText = ""
    @State private var sizesByID: [String: Int64] = [:]
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<String>()
    @State private var showDeleteAllConfirm = false
    @State private var seriesPendingDelete: SeriesInfo?

    private var isEditing: Bool { editMode.isEditing }

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
            List(selection: $selection) {
                downloadsSection
                if !isEditing {
                    activitySection
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.editMode, $editMode)
            .navigationTitle("My Activity")
            .navigationDestination(for: SeriesInfo.self) { series in
                SeriesDetailView(seriesInfo: series)
            }
            .searchable(text: $searchText, prompt: "Search downloads")
            .task(id: downloads.downloadedIDs) { sizesByID = await downloads.downloadedSizes() }
            .toolbar { downloadsToolbar }
            .safeAreaInset(edge: .bottom) {
                if isEditing {
                    multiSelectDeleteBar
                } else {
                    Spacer().frame(height: 70)
                }
            }
            .confirmationDialog(
                "Delete all \(downloads.downloadedIDs.count) downloaded discourses?",
                isPresented: $showDeleteAllConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) {
                    downloads.deleteAllDownloads()
                    exitEditing()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the audio files from this device. Your bookmarks and listening history are kept.")
            }
            .confirmationDialog(
                seriesPendingDelete.map { "Delete all downloads in \($0.name)?" } ?? "",
                isPresented: Binding(
                    get: { seriesPendingDelete != nil },
                    set: { if !$0 { seriesPendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Series Downloads", role: .destructive) {
                    if let series = seriesPendingDelete {
                        let ids = Catalog.discourses(for: series)
                            .map(\.id)
                            .filter { downloads.isDownloaded($0) }
                        downloads.deleteDownloads(ids: ids)
                    }
                    seriesPendingDelete = nil
                }
                Button("Cancel", role: .cancel) { seriesPendingDelete = nil }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var downloadsToolbar: some ToolbarContent {
        if !filteredDownloads.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                if isEditing {
                    Button("Done") { exitEditing() }
                } else {
                    Menu {
                        Button {
                            withAnimation { editMode = .active }
                        } label: {
                            Label("Select", systemImage: "checkmark.circle")
                        }
                        Button(role: .destructive) {
                            showDeleteAllConfirm = true
                        } label: {
                            Label("Delete All", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }

    // MARK: - Multi-select delete bar

    private var multiSelectDeleteBar: some View {
        HStack {
            Text(selection.isEmpty ? "Select discourses" : "\(selection.count) selected")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button(role: .destructive) {
                downloads.deleteDownloads(ids: Array(selection))
                exitEditing()
            } label: {
                Text("Delete")
                    .fontWeight(.semibold)
            }
            .disabled(selection.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private func exitEditing() {
        withAnimation {
            editMode = .inactive
            selection.removeAll()
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
            ForEach(Array(filteredDownloads.enumerated()), id: \.element.seriesInfo.id) { index, group in
                Section {
                    ForEach(group.discourses) { discourse in
                        DownloadedDiscourseRow(
                            discourse: discourse,
                            seriesInfo: group.seriesInfo,
                            sizeText: sizeText(for: sizesByID[discourse.id])
                        )
                        .tag(discourse.id)
                    }
                    .onDelete { indexSet in
                        deleteDiscourses(at: indexSet, in: group.discourses)
                    }
                } header: {
                    DownloadedSeriesHeader(
                        seriesInfo: group.seriesInfo,
                        count: group.discourses.count,
                        sizeText: seriesSizeText(for: group.discourses),
                        onDeleteSeries: isEditing ? nil : { seriesPendingDelete = group.seriesInfo }
                    )
                } footer: {
                    // Tip + storage live as plain footer text under the last
                    // section — small and informational, not a tappable card.
                    if index == filteredDownloads.count - 1 {
                        downloadsFooter
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var downloadsFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !isEditing {
                Text("Swipe a discourse left to delete, or use a series' ••• menu to clear a whole series or select several.")
            }
            if totalBytes > 0 && searchText.isEmpty {
                Text("\(format(totalBytes)) used on this device")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var totalBytes: Int64 {
        sizesByID.values.reduce(0, +)
    }

    /// Per-series size summed from the discourse-level map.
    private func seriesSizeText(for discourses: [CatalogDiscourse]) -> String? {
        let bytes = discourses.reduce(Int64(0)) { $0 + (sizesByID[$1.id] ?? 0) }
        return bytes > 0 ? format(bytes) : nil
    }

    private func sizeText(for bytes: Int64?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        return format(bytes)
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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
    let sizeText: String?
    /// When non-nil, shows a ••• menu offering to delete the whole series.
    let onDeleteSeries: (() -> Void)?

    private var subtitle: String {
        var parts = ["\(count) episodes"]
        if let sizeText { parts.append(sizeText) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            NavigationLink(value: seriesInfo) {
                HStack(spacing: 10) {
                    SeriesThumbnailView(name: seriesInfo.name, size: 32)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(seriesInfo.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)

                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            if let onDeleteSeries {
                Menu {
                    Button(role: .destructive, action: onDeleteSeries) {
                        Label("Delete All in Series", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Discourse Row

private struct DownloadedDiscourseRow: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(DownloadService.self) private var downloads
    @Environment(\.editMode) private var editMode
    let discourse: CatalogDiscourse
    let seriesInfo: SeriesInfo
    let sizeText: String?

    private var isCurrentlyPlaying: Bool {
        player.currentTrackId == discourse.id
    }

    private var isEditing: Bool { editMode?.wrappedValue.isEditing == true }

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

            if let sizeText {
                Text(sizeText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            // Hide the play button in edit mode so the row reads as selectable.
            if !isEditing {
                Button {
                    playDiscourse()
                } label: {
                    Image(systemName: isCurrentlyPlaying && player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .contentShape(Rectangle())
        // In edit mode let the List handle selection; only play on tap otherwise.
        .onTapGesture {
            guard !isEditing else { return }
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
