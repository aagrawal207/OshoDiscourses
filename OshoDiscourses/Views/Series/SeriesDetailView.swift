import SwiftUI

struct SeriesDetailView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(DownloadService.self) private var downloads
    @Environment(PlaybackStateService.self) private var playbackState
    let seriesInfo: SeriesInfo
    @State private var showDownloadAllConfirm = false

    private var discourses: [CatalogDiscourse] {
        Catalog.discourses(for: seriesInfo)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                headerSection
                downloadAllButton
                discourseList
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle(seriesInfo.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        for discourse in discourses {
                            playbackState.markCompleted(discourseId: discourse.id)
                        }
                    } label: {
                        Label("Mark All Complete", systemImage: "checkmark.circle.fill")
                    }
                    Button(role: .destructive) {
                        for discourse in discourses {
                            playbackState.unmarkCompleted(discourseId: discourse.id)
                        }
                    } label: {
                        Label("Mark All Incomplete", systemImage: "xmark.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private var headerSection: some View {
        VStack(spacing: 16) {
            SeriesThumbnailView(name: seriesInfo.name, size: 120)
                .shadow(color: .primary.opacity(0.1), radius: 20)

            VStack(spacing: 6) {
                Text(seriesInfo.name)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                HStack(spacing: 8) {
                    Text("\(seriesInfo.count) discourses")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text("·")
                        .foregroundStyle(.secondary)

                    Text(seriesInfo.language == .hindi ? "Hindi" : "English")
                        .font(.subheadline)
                        .foregroundStyle(Color.accent)
                }

                let completedCount = playbackState.completedCount(for: seriesInfo.id)
                if completedCount > 0 {
                    Text("\(completedCount)/\(seriesInfo.count) completed")
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                if let meta = SeriesMetadata.description(for: seriesInfo.name) {
                    VStack(spacing: 8) {
                        Text(meta.sourceText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(4)

                        if let year = meta.year, let location = meta.location {
                            Text("\(location), \(year)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }

                        if !meta.themes.isEmpty {
                            FlowLayout(spacing: 4) {
                                ForEach(meta.themes.prefix(5), id: \.self) { theme in
                                    Text(theme)
                                        .font(.system(size: 10))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.accent.opacity(0.1))
                                        .foregroundStyle(Color.accent)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }
                    .padding(.top, 8)
                    .padding(.horizontal, 16)
                }
            }
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }

    private var remainingCount: Int {
        discourses.filter { !downloads.isDownloaded($0.id) }.count
    }

    private var estimatedTotalSize: String {
        let perFile = seriesInfo.language == .hindi ? 20 : 30
        let totalMB = remainingCount * perFile
        if totalMB >= 1000 {
            return String(format: "~%.1f GB", Double(totalMB) / 1000.0)
        }
        return "~\(totalMB) MB"
    }

    private var downloadAllButton: some View {
        Button {
            showDownloadAllConfirm = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                Text("Download All")
                    .fontWeight(.semibold)
                if remainingCount > 0 {
                    Text("(\(remainingCount) · \(estimatedTotalSize))")
                        .fontWeight(.regular)
                        .opacity(0.8)
                }
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.accent.opacity(0.15))
            .foregroundStyle(Color.accent)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(.horizontal)
        .padding(.bottom, 20)
        .confirmationDialog(
            "Download \(remainingCount) discourses?",
            isPresented: $showDownloadAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Download \(remainingCount) (\(estimatedTotalSize))") {
                Task {
                    for discourse in discourses where !downloads.isDownloaded(discourse.id) {
                        _ = try? await downloads.download(discourse)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will download \(remainingCount) discourses using approximately \(estimatedTotalSize) of storage.")
        }
    }

    private var discourseList: some View {
        LazyVStack(spacing: 0) {
            ForEach(discourses) { discourse in
                DiscourseRowView(discourse: discourse, seriesInfo: seriesInfo)
                    .id("\(discourse.id)-\(playbackState.isCompleted(discourse.id))")

                if discourse.id != discourses.last?.id {
                    Divider()
                        .padding(.leading, 52)
                }
            }
        }
    }
}

// MARK: - Discourse Row

private struct DiscourseRowView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(DownloadService.self) private var downloads
    @Environment(PlaybackStateService.self) private var playbackState
    let discourse: CatalogDiscourse
    let seriesInfo: SeriesInfo
    @State private var showDownloadHint = false

    private var isCurrentlyPlaying: Bool {
        player.currentTrackId == discourse.id && player.isPlaying
    }

    private var isDownloaded: Bool {
        downloads.isDownloaded(discourse.id)
    }

    private var isCompleted: Bool {
        playbackState.isCompleted(discourse.id)
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Text("\(discourse.number)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if isCompleted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                        .offset(x: 10, y: -8)
                }
            }
            .frame(width: 28, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(discourse.displayTitle)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundStyle(isCurrentlyPlaying ? .blue : .primary)

                if showDownloadHint {
                    Text("Downloading...")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }

            Spacer()

            actionButton
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            playDiscourse()
        }
        .contextMenu {
            if playbackState.isCompleted(discourse.id) {
                Button {
                    playbackState.unmarkCompleted(discourseId: discourse.id)
                } label: {
                    Label("Mark as Incomplete", systemImage: "xmark.circle")
                }
            } else {
                Button {
                    playbackState.markCompleted(discourseId: discourse.id)
                } label: {
                    Label("Mark as Complete", systemImage: "checkmark.circle")
                }
            }
        }
    }

    private var estimatedSize: String {
        seriesInfo.language == .hindi ? "~20 MB" : "~30 MB"
    }

    private var isFailed: Bool {
        guard let dl = downloads.activeDownloads[discourse.id] else { return false }
        if case .failed = dl.status { return true }
        return false
    }

    @ViewBuilder
    private var actionButton: some View {
        if downloads.isDownloading(discourse.id) {
            Button {
                downloads.cancelDownload(discourseID: discourse.id)
            } label: {
                CircularProgressView(progress: downloads.progress(for: discourse.id))
                    .frame(width: 28, height: 28)
            }
        } else if isFailed {
            Button {
                downloads.activeDownloads.removeValue(forKey: discourse.id)
                Task { _ = try? await downloads.download(discourse) }
            } label: {
                Image(systemName: "exclamationmark.arrow.circlepath")
                    .font(.title3)
                    .foregroundStyle(.red)
            }
        } else if isDownloaded {
            Button {
                playDiscourse()
            } label: {
                Image(systemName: isCurrentlyPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accent)
            }
        } else {
            Button {
                Task { _ = try? await downloads.download(discourse) }
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
        }
    }

    private func playDiscourse() {
        guard downloads.localFileURL(for: discourse.id) != nil else {
            // Not downloaded yet — start download and show hint
            Task { _ = try? await downloads.download(discourse) }
            withAnimation {
                showDownloadHint = true
            }
            Task {
                try? await Task.sleep(for: .seconds(2))
                withAnimation {
                    showDownloadHint = false
                }
            }
            return
        }

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

// MARK: - Circular Progress

private struct CircularProgressView: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.15), lineWidth: 2.5)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))

            Image(systemName: "stop.fill")
                .font(.system(size: 8))
                .foregroundStyle(Color.accent)
        }
    }
}
