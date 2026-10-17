import SwiftUI

struct DownloadsView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(DownloadService.self) private var downloads
    @Environment(PlaybackStateService.self) private var playbackState
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Bindable private var settings = UserSettings.shared
    private var bookmarkService = BookmarkService.shared
    @State private var searchText = ""
    @State private var sizesByID: [String: Int64] = [:]
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<String>()
    @State private var showDeleteAllConfirm = false
    @State private var seriesPendingDelete: SeriesInfo?
    @State private var translationSizes: [String: Int64] = [:]
    @State private var openedTranslation: NarrationDocument?
    private let narrations = NarrationService.shared

    private var isEditing: Bool { editMode.isEditing }

    /// A downloaded recording or a translation saved on this device; both play offline.
    enum SavedItem: Identifiable {
        case recording(CatalogDiscourse)
        case translation(NarrationDocument, CatalogDiscourse)

        var id: String {
            switch self {
            case .recording(let discourse): discourse.id
            case .translation(let document, _): document.id
            }
        }

        var discourse: CatalogDiscourse {
            switch self {
            case .recording(let discourse), .translation(_, let discourse): discourse
            }
        }
    }

    struct SavedGroup {
        let seriesInfo: SeriesInfo
        var items: [SavedItem]
    }

    /// Translations made on this device; preview builds without the feature have none.
    private var savedTranslations: [NarrationDocument] {
        #if TRANSLATED_NARRATION
        narrations.documents
        #else
        []
        #endif
    }

    private var finishedTranslations: [NarrationDocument] { savedTranslations.filter(\.isComplete) }

    /// Translations still being made, or stopped part way; one just started may have no passage yet.
    private var unfinishedTranslations: [NarrationDocument] {
        savedTranslations.filter {
            !$0.isComplete && Catalog.discourseLookup[$0.discourseID] != nil
                && (!$0.segments.isEmpty || narrations.preparingDocumentID == $0.id)
        }
    }

    private var groupedDownloads: [SavedGroup] {
        var groups: [String: SavedGroup] = [:]
        for group in downloads.downloadedDiscourses() {
            groups[group.seriesInfo.id] = SavedGroup(seriesInfo: group.seriesInfo, items: group.discourses.map { .recording($0) })
        }
        for document in finishedTranslations {
            guard let (discourse, series) = Catalog.discourseLookup[document.discourseID] else { continue }
            groups[series.id, default: SavedGroup(seriesInfo: series, items: [])].items.append(.translation(document, discourse))
        }
        return groups.values.map { group in
            var group = group
            // A recording leads its own translations, then languages in a stable order.
            group.items.sort { lhs, rhs in
                if lhs.discourse.number != rhs.discourse.number { return lhs.discourse.number < rhs.discourse.number }
                switch (lhs, rhs) {
                case (.recording, .translation): return true
                case (.translation, .recording): return false
                default: return lhs.id < rhs.id
                }
            }
            return group
        }
        .sorted { $0.seriesInfo.name < $1.seriesInfo.name }
    }

    private var filteredDownloads: [SavedGroup] {
        guard !searchText.isEmpty else { return groupedDownloads }
        let query = searchText.lowercased()
        return groupedDownloads.compactMap { group in
            let matchesSeries = group.seriesInfo.name.lowercased().contains(query)
            let matching = group.items.filter { item in
                if matchesSeries || item.discourse.displayTitle.lowercased().contains(query) { return true }
                guard case .translation(let document, _) = item else { return false }
                return Self.languageName(document).lowercased().contains(query) || "translation".contains(query)
            }
            guard !matching.isEmpty else { return nil }
            return SavedGroup(seriesInfo: group.seriesInfo, items: matching)
        }
    }

    fileprivate static func languageName(_ document: NarrationDocument) -> String {
        NarrationLanguageSupport.displayName(for: document.selection.targetLanguage)
    }

    /// Discourses currently downloading or queued, in run order (active first,
    /// then the queue). Surfaced here so progress is visible from My Activity,
    /// not only the series page.
    private var inProgress: [CatalogDiscourse] {
        downloads.inProgressIDs().compactMap { Catalog.discourseLookup[$0]?.discourse }
    }

    /// Discourses that were downloaded before but aren't on disk now — offered
    /// for quick re-download. Sorted by series then number for a stable list.
    private var previouslyDownloaded: [CatalogDiscourse] {
        downloads.downloadHistory
            .subtracting(downloads.downloadedIDs)
            .compactMap { Catalog.discourseLookup[$0]?.discourse }
            .filter { !downloads.isDownloading($0.id) }
            .sorted { ($0.seriesName, $0.number) < ($1.seriesName, $1.number) }
    }

    var body: some View {
        NavigationStack {
            List(selection: $selection) {
                if !isEditing {
                    inProgressSection
                }
                downloadsSection
                if !isEditing {
                    previouslyDownloadedSection
                    activitySection
                }
            }
            .listStyle(.insetGrouped)
            .readableScrollColumn(sizeClass, maxWidth: AppLayout.listMaxWidth)
            .environment(\.editMode, $editMode)
            .navigationTitle("Downloads")
            .navigationDestination(for: SeriesInfo.self) { series in
                SeriesDetailView(seriesInfo: series)
            }
            .searchable(text: $searchText, prompt: "Search downloads")
            .task(id: downloads.downloadedIDs) { sizesByID = await downloads.downloadedSizes() }
            .task { await narrations.loadIfNeeded() }
            // Sizes change as passages are saved and after joining frees them.
            .task(id: narrations.documents.map { "\($0.id):\($0.segments.count):\($0.isComplete)" } + ["\(narrations.storageRevision)"]) {
                translationSizes = await narrations.storageSizes()
            }
            .toolbar { downloadsToolbar }
            .safeAreaInset(edge: .bottom) {
                if isEditing { multiSelectDeleteBar }
            }
            .reservesMiniPlayerSpace()
            .confirmationDialog(
                deleteAllTitle,
                isPresented: $showDeleteAllConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) {
                    let translations = finishedTranslations.map(\.id)
                    downloads.deleteAllDownloads()
                    removeTranslations(translations)
                    exitEditing()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(finishedTranslations.isEmpty
                     ? "This removes the audio files from this device. Your bookmarks and listening history are kept."
                     : "This removes the audio files from this device. Translations can be made again from the transcript. Your bookmarks and listening history are kept.")
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
                        let ids = groupedDownloads.first { $0.seriesInfo.id == series.id }?.items.map(\.id) ?? []
                        deleteItems(ids: ids)
                    }
                    seriesPendingDelete = nil
                }
                Button("Cancel", role: .cancel) { seriesPendingDelete = nil }
            }
            .sheet(item: $openedTranslation) { document in
                #if TRANSLATED_NARRATION
                if #available(macCatalyst 26.0, *) {
                    TranslatedNarrationView(discourseID: document.discourseID, selectedDocumentID: document.id)
                        .environment(player)
                        .environment(downloads)
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                }
                #endif
            }
        }
    }

    private var deleteAllTitle: String {
        let recordings = downloads.downloadedIDs.count
        let translations = finishedTranslations.count
        switch (recordings, translations) {
        case (_, 0): return "Delete all \(recordings) downloaded discourses?"
        case (0, _): return "Delete all \(translations) translations?"
        default: return "Delete all \(recordings) downloads and \(translations) translations?"
        }
    }

    /// Recordings and translations share one selection; translation IDs are rendition hashes.
    private func deleteItems(ids: [String]) {
        let translations = ids.filter(NarrationCache.isID)
        downloads.deleteDownloads(ids: ids.filter { !NarrationCache.isID($0) })
        removeTranslations(translations)
    }

    private func removeTranslations(_ ids: [String]) {
        let documents = ids.compactMap { id in narrations.documents.first { $0.id == id } }
        guard !documents.isEmpty else { return }
        Task {
            for document in documents { await removeTranslation(document, player: player) }
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
                    .accessibilityLabel("More options")
                }
            }
        }
    }

    // MARK: - Multi-select delete bar

    private var multiSelectDeleteBar: some View {
        HStack {
            Text(selection.isEmpty ? "Select downloads" : "\(selection.count) selected")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button(role: .destructive) {
                deleteItems(ids: Array(selection))
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
                        ? "Downloaded discourses and translations will appear here."
                        : "No downloads match \"\(searchText)\".")
                )
            }
            .listRowBackground(Color.clear)
        } else {
            ForEach(Array(filteredDownloads.enumerated()), id: \.element.seriesInfo.id) { index, group in
                Section {
                    ForEach(group.items) { item in
                        switch item {
                        case .recording(let discourse):
                            DownloadedDiscourseRow(
                                discourse: discourse,
                                seriesInfo: group.seriesInfo,
                                sizeText: sizeText(for: sizesByID[discourse.id])
                            )
                            .tag(discourse.id)
                        case .translation(let document, let discourse):
                            TranslationRow(
                                document: document, discourse: discourse,
                                sizeText: sizeText(for: translationSizes[document.id]),
                                open: { openedTranslation = document },
                                remove: { removeTranslations([document.id]) }
                            )
                            .tag(document.id)
                        }
                    }
                    .onDelete { indexSet in
                        deleteItems(ids: indexSet.map { group.items[$0].id })
                    }
                } header: {
                    DownloadedSeriesHeader(
                        seriesInfo: group.seriesInfo,
                        recordings: group.items.filter { if case .recording = $0 { true } else { false } }.count,
                        translations: group.items.filter { if case .translation = $0 { true } else { false } }.count,
                        sizeText: seriesSizeText(for: group.items),
                        onDeleteSeries: isEditing ? nil : { seriesPendingDelete = group.seriesInfo }
                    )
                } footer: {
                    // Hint + storage live as plain footer text under the last
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
        VStack(alignment: .leading, spacing: 8) {
            let showHint = !isEditing
            let showUsage = totalBytes > 0 && searchText.isEmpty
            if showHint {
                Text("Swipe left to delete, or use a series' ••• menu to clear a whole series or select several.")
            }
            if showHint && showUsage {
                Divider()
            }
            if showUsage {
                let translations = translationSizes.values.reduce(0, +)
                Text(translations > 0
                     ? "\(format(totalBytes)) used on this device, including \(format(translations)) of translations"
                     : "\(format(totalBytes)) used on this device")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - In Progress Section

    /// Live downloads (transferring + queued) so progress is visible from My
    /// Activity. Hidden while searching or when nothing is in flight.
    @ViewBuilder
    private var inProgressSection: some View {
        let items = searchText.isEmpty ? inProgress : []
        let translations = searchText.isEmpty ? unfinishedTranslations : []
        if !items.isEmpty || !translations.isEmpty {
            Section {
                if !items.isEmpty, downloads.waitingReason != nil { DownloadWaitingNotice() }
                ForEach(items) { discourse in
                    InProgressRow(discourse: discourse)
                }
                ForEach(translations) { document in
                    TranslationProgressRow(document: document, sizeText: sizeText(for: translationSizes[document.id])) {
                        openedTranslation = document
                    }
                }
                .onDelete { offsets in removeTranslations(offsets.map { translations[$0].id }) }
            } header: {
                Text(translations.isEmpty ? "Downloading" : "In Progress")
            } footer: {
                switch (items.isEmpty, translations.isEmpty) {
                case (false, true): Text("Downloads run one at a time. Tap to cancel.")
                case (true, false): Text("Tap a translation to continue or pause it.")
                default: Text("Downloads run one at a time; tap one to cancel. Tap a translation to continue or pause it.")
                }
            }
        }
    }

    // MARK: - Previously Downloaded Section

    /// Shown only when there's history not currently on disk and the user isn't
    /// searching, so it never clutters the normal or empty state.
    @ViewBuilder
    private var previouslyDownloadedSection: some View {
        let items = searchText.isEmpty ? previouslyDownloaded : []
        if !items.isEmpty {
            Section {
                ForEach(items) { discourse in
                    RedownloadRow(discourse: discourse)
                }
                .onDelete { offsets in
                    let ids = offsets.map { items[$0].id }
                    downloads.forgetDownloadHistory(ids: ids)
                }
            } header: {
                Text("Previously Downloaded")
            } footer: {
                Text("Removed from this device. Tap to download again, or swipe to remove from this list.")
            }
        }
    }

    private var totalBytes: Int64 {
        sizesByID.values.reduce(0, +) + translationSizes.values.reduce(0, +)
    }

    /// Per-series size summed from the recording and translation maps.
    private func seriesSizeText(for items: [SavedItem]) -> String? {
        let bytes = items.reduce(Int64(0)) { $0 + (sizesByID[$1.id] ?? translationSizes[$1.id] ?? 0) }
        return bytes > 0 ? format(bytes) : nil
    }

    private func sizeText(for bytes: Int64?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        return format(bytes)
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

}

// MARK: - Series Header

private struct DownloadedSeriesHeader: View {
    let seriesInfo: SeriesInfo
    let recordings: Int
    let translations: Int
    let sizeText: String?
    /// When non-nil, shows a ••• menu offering to delete the whole series.
    let onDeleteSeries: (() -> Void)?

    private var subtitle: String {
        var parts: [String] = []
        if recordings > 0 { parts.append(recordings == 1 ? "1 episode" : "\(recordings) episodes") }
        if translations > 0 { parts.append(translations == 1 ? "1 translation" : "\(translations) translations") }
        if let sizeText { parts.append(sizeText) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            NavigationLink(value: seriesInfo) {
                HStack(spacing: 10) {
                    SeriesThumbnailView(name: seriesInfo.name, size: 32, seriesID: seriesInfo.id)

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
                .accessibilityLabel("Series options")
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
    @Environment(AppNavigation.self) private var navigation: AppNavigation?
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

            // The series name is in the section header above, so the row just
            // labels the discourse — no repeated, truncated series name.
            Text("Discourse \(discourse.number)")
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
                .accessibilityLabel(isCurrentlyPlaying && player.isPlaying ? "Pause" : "Play")
            }
        }
        .contentShape(Rectangle())
        // In edit mode let the List handle selection; only play on tap otherwise.
        .onTapGesture {
            guard !isEditing else { return }
            playDiscourse()
        }
        // The tap gesture on a plain HStack is invisible to VoiceOver — expose
        // the row as a button with the same guarded action.
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Discourse \(discourse.number)")
        .accessibilityHint("Plays this discourse")
        .accessibilityAction {
            guard !isEditing else { return }
            playDiscourse()
        }
        .hoverEffect(.highlight)
        .contextMenu {
            if !isEditing {
                Button {
                    if isCurrentlyPlaying { player.togglePlayPause() } else { playDiscourse() }
                } label: {
                    let pauses = isCurrentlyPlaying && player.isPlaying
                    Label(pauses ? "Pause" : "Play", systemImage: pauses ? "pause" : "play")
                }
                if isCurrentlyPlaying, let navigation {
                    Button {
                        navigation.addBookmark()
                    } label: {
                        Label("Add Bookmark…", systemImage: "bookmark")
                    }
                }
                Divider()
                Button(role: .destructive) {
                    try? downloads.deleteDownload(discourseID: discourse.id)
                } label: {
                    Label("Remove Download", systemImage: "trash")
                }
            }
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

// MARK: - Re-download Row

/// A row for a previously-downloaded discourse no longer on disk. Shows the
/// series + number and a control to fetch it again, mirroring the series
/// screen's GET / progress / cancel affordances.
private struct RedownloadRow: View {
    @Environment(DownloadService.self) private var downloads
    let discourse: CatalogDiscourse

    private var isDownloading: Bool { downloads.isDownloading(discourse.id) }

    private var estimatedSize: String {
        discourse.language == .hindi ? "~20 MB" : "~30 MB"
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                // Flat list (not grouped under a series header), so show the full
                // series name — wrap rather than truncate long ones.
                Text(discourse.seriesName)
                    .font(.body)
                    .lineLimit(2)
                Text("Discourse \(discourse.number)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isDownloading {
                Button {
                    downloads.cancelDownload(discourseID: discourse.id)
                } label: {
                    // Queued items show an indeterminate spinner; active ones a
                    // determinate ring that tracks real bytes-downloaded.
                    if downloads.isQueued(discourse.id) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .frame(width: 26, height: 26)
                    } else {
                        ProgressView(value: downloads.progress(for: discourse.id))
                            .progressViewStyle(.circular)
                            .frame(width: 26, height: 26)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel download")
                .accessibilityValue(downloads.isQueued(discourse.id) ? "Queued" : "\(Int(downloads.progress(for: discourse.id) * 100)) percent")
            } else {
                Button {
                    downloads.startDownload(discourse)
                } label: {
                    Text("GET \(estimatedSize)")
                        .font(.caption.bold())
                        .fixedSize()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.accent.opacity(0.15))
                        .foregroundStyle(Color.accent)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - In-Progress Row

/// A row for a discourse that's currently downloading or queued. Shows the
/// series + number, a status line (percent while transferring, "Queued" while
/// waiting), a linear bar for the active transfer, and an X to cancel.
private struct InProgressRow: View {
    @Environment(DownloadService.self) private var downloads
    let discourse: CatalogDiscourse

    private var isQueued: Bool { downloads.isQueued(discourse.id) }
    private var progress: Double { downloads.progress(for: discourse.id) }
    private var statusText: String {
        downloads.waitingReason?.rowLabel ?? "\(Int(progress * 100))%"
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                // Flat list — show the full series name, wrapping if long.
                Text(discourse.seriesName)
                    .font(.body)
                    .lineLimit(2)
                Text("Discourse \(discourse.number)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if isQueued {
                    Text("Queued")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView(value: progress)
                        .tint(Color.accent)
                    Text(statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Spacer()

            Button {
                downloads.cancelDownload(discourseID: discourse.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel download")
            .accessibilityValue(isQueued ? "Queued" : downloads.waitingReason?.rowLabel ?? "\(Int(progress * 100)) percent")
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Translation Rows

/// Shares the translation screen's deletion, which also stops the rendition's playback and translation.
@MainActor
private func removeTranslation(_ document: NarrationDocument, player: AudioPlayerService) async {
    #if TRANSLATED_NARRATION
    if #available(macCatalyst 26.0, *) {
        try? await NarrationPreparationController.shared.delete(document, player: player)
        return
    }
    #endif
    if player.currentNarration?.id == document.id { player.stop() }
    try? await NarrationService.shared.remove(document.id)
}

/// Plays a saved translation from its own position, or from the moment the recording reached when switching.
@MainActor
private func playTranslation(_ document: NarrationDocument, player: AudioPlayerService) {
    if player.currentNarration?.id == document.id, player.narrationPlaybackFailure == nil {
        player.togglePlayPause()
        return
    }
    #if TRANSLATED_NARRATION
    let loadedTrack = player.currentTrackId
    Task {
        let start = await TranslatedListening.translatedStart(for: document, player: player)
        guard player.currentTrackId == loadedTrack else { return }
        NarrationPreviewPlayback.shared.play(documentID: document.id, player: player, resumeAt: start)
    }
    #endif
}

/// A finished translation, listed under its series beside the downloaded recordings.
private struct TranslationRow: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.editMode) private var editMode
    let document: NarrationDocument
    let discourse: CatalogDiscourse
    let sizeText: String?
    let open: () -> Void
    let remove: () -> Void
    private let narrations = NarrationService.shared

    private var isCurrent: Bool { player.currentNarration?.id == document.id }
    private var isEditing: Bool { editMode?.wrappedValue.isEditing == true }
    private var isPlayable: Bool { narrations.audioURL(for: document) != nil }
    private var language: String { DownloadsView.languageName(document) }

    var body: some View {
        HStack(spacing: 12) {
            Text("\(discourse.number)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("Discourse \(discourse.number)")
                    .font(.body)
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? Color.accent : .primary)
                Label(isPlayable ? "\(language) translation · \(document.selection.voice.name)" : "\(language) translation · Audio missing",
                      systemImage: "globe")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let sizeText {
                Text(sizeText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if !isEditing {
                Button(action: activate) {
                    Image(systemName: isPlayable
                          ? (isCurrent && player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                          : "arrow.clockwise.circle")
                        .font(.title3)
                        .foregroundStyle(Color.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlayable ? (isCurrent && player.isPlaying ? "Pause" : "Play") : "Rebuild")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isEditing else { return }
            activate()
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Discourse \(discourse.number), \(language) translation")
        .accessibilityIdentifier("downloads.translation.\(document.id)")
        .accessibilityHint(isPlayable ? "Plays this translation" : "Opens the translation to rebuild its audio")
        .accessibilityAction {
            guard !isEditing else { return }
            activate()
        }
        .hoverEffect(.highlight)
        .contextMenu {
            if !isEditing {
                if isPlayable {
                    Button(action: activate) {
                        let pauses = isCurrent && player.isPlaying
                        Label(pauses ? "Pause" : "Play", systemImage: pauses ? "pause" : "play")
                    }
                }
                Button(action: open) {
                    Label("Read Along and Options", systemImage: "doc.plaintext")
                }
                Divider()
                Button(role: .destructive, action: remove) {
                    Label("Remove Translation", systemImage: "trash")
                }
            }
        }
    }

    private func activate() {
        if isPlayable { playTranslation(document, player: player) } else { open() }
    }
}

/// A translation still being made or stopped part way. Tapping opens it to continue or pause.
private struct TranslationProgressRow: View {
    @Environment(AudioPlayerService.self) private var player
    let document: NarrationDocument
    let sizeText: String?
    let open: () -> Void
    private let narrations = NarrationService.shared

    private var discourse: CatalogDiscourse? { Catalog.discourseLookup[document.discourseID]?.discourse }
    private var isTranslating: Bool { narrations.preparingDocumentID == document.id }
    private var isCurrent: Bool { player.currentNarration?.id == document.id }
    private var canPlay: Bool { narrations.playablePrefix(of: document.id) != nil }
    private var fraction: Double {
        if isTranslating, narrations.progress.isFinite { return min(1, max(0, narrations.progress)) }
        return Double(document.segments.count) / Double(max(1, document.expectedSegmentCount))
    }
    private var status: String {
        let passages = NarrationTimeFormatting.passages(document.segments.count, of: document.expectedSegmentCount)
        return (isTranslating ? "Translating · " : "Paused · ") + passages
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(discourse?.seriesName ?? "Saved discourse")
                        .font(.body)
                        .lineLimit(2)
                    Label("Discourse \(discourse?.number ?? 0) · \(DownloadsView.languageName(document)) translation", systemImage: "globe")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ProgressView(value: fraction)
                        .tint(Color.accent)
                    HStack {
                        Text(status)
                        Spacer()
                        if let sizeText { Text(sizeText) }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens the translation to continue or pause it")
            .accessibilityIdentifier("downloads.translationProgress.\(document.id)")

            if canPlay {
                Button { playTranslation(document, player: player) } label: {
                    Image(systemName: isCurrent && player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCurrent && player.isPlaying ? "Pause" : "Play the finished part")
            }
        }
    }
}
