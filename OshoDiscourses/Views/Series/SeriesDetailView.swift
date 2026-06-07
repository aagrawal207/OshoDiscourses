import SwiftUI

struct SeriesDetailView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(DownloadService.self) private var downloads
    let seriesInfo: SeriesInfo

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
    }

    private var headerSection: some View {
        VStack(spacing: 16) {
            SeriesThumbnailView(name: seriesInfo.name, size: 120)
                .shadow(color: .white.opacity(0.1), radius: 20)

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
                        .foregroundStyle(.blue)
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
            Task {
                for discourse in discourses where !downloads.isDownloaded(discourse.id) {
                    _ = try? await downloads.download(discourse)
                }
            }
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
            .background(Color.blue.opacity(0.15))
            .foregroundStyle(.blue)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(.horizontal)
        .padding(.bottom, 20)
    }

    private var discourseList: some View {
        LazyVStack(spacing: 0) {
            ForEach(discourses) { discourse in
                DiscourseRowView(discourse: discourse, seriesInfo: seriesInfo)

                if discourse.id != discourses.last?.id {
                    Divider()
                        .background(Color.white.opacity(0.1))
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
    let discourse: CatalogDiscourse
    let seriesInfo: SeriesInfo

    private var isCurrentlyPlaying: Bool {
        player.currentTrackId == discourse.id && player.isPlaying
    }

    private var isDownloaded: Bool {
        downloads.isDownloaded(discourse.id)
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("\(discourse.number)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(discourse.displayTitle)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundStyle(isCurrentlyPlaying ? .blue : .primary)
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
    }

    private var estimatedSize: String {
        seriesInfo.language == .hindi ? "~20 MB" : "~30 MB"
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
        } else if isDownloaded {
            Button {
                playDiscourse()
            } label: {
                Image(systemName: isCurrentlyPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
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
                    .background(Color.blue.opacity(0.15))
                    .foregroundStyle(.blue)
                    .clipShape(Capsule())
            }
        }
    }

    private func playDiscourse() {
        guard let url = downloads.localFileURL(for: discourse.id) else { return }

        let allDiscourses = Catalog.discourses(for: seriesInfo)
        let queueItems = allDiscourses
            .filter { downloads.isDownloaded($0.id) }
            .map { d in
                AudioPlayerService.QueueItem(
                    id: d.id,
                    url: downloads.localFileURL(for: d.id)!,
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
                .stroke(Color.white.opacity(0.1), lineWidth: 2.5)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.blue, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))

            Image(systemName: "stop.fill")
                .font(.system(size: 8))
                .foregroundStyle(.blue)
        }
    }
}
