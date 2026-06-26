import SwiftUI

struct HomeView: View {
    @State private var navigationPath = NavigationPath()
    @Environment(DownloadService.self) private var downloads
    @Environment(PlaybackStateService.self) private var playbackState
    @Environment(AudioPlayerService.self) private var player
    private var settings = UserSettings.shared

    private var popularEnglish: [SeriesInfo] {
        guard !settings.hideEnglish else { return [] }
        return Catalog.popularEnglish
    }

    private var beginnerEnglish: [SeriesInfo] {
        guard !settings.hideEnglish else { return [] }
        return Catalog.beginnerEnglish
    }

    private var popularHindi: [SeriesInfo] {
        guard !settings.hideHindi else { return [] }
        return Catalog.popularHindi
    }

    private var beginnerHindi: [SeriesInfo] {
        guard !settings.hideHindi else { return [] }
        return Catalog.beginnerHindi
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if !continueListening.isEmpty {
                        continueListeningSection
                    }

                    if !recentlyCompleted.isEmpty {
                        recentlyCompletedSection
                    }

                    if !popularEnglish.isEmpty {
                        SeriesSectionView(title: "Popular in English", series: popularEnglish)
                    }
                    if !beginnerEnglish.isEmpty {
                        SeriesSectionView(title: "Beginner Friendly (English)", series: beginnerEnglish)
                    }
                    if !popularHindi.isEmpty {
                        SeriesSectionView(title: "Popular in Hindi", series: popularHindi)
                    }
                    if !beginnerHindi.isEmpty {
                        SeriesSectionView(title: "Beginner Friendly (Hindi)", series: beginnerHindi)
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 70)
            }
            .background(Color(.systemBackground))
            .navigationTitle("Home")
            .navigationDestination(for: SeriesInfo.self) { series in
                SeriesDetailView(seriesInfo: series)
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigateToSeries)) { notification in
                if let series = notification.object as? SeriesInfo {
                    navigationPath = NavigationPath()
                    navigationPath.append(series)
                }
            }
        }
    }

    // MARK: - Continue Listening

    struct ContinueItem: Identifiable {
        let id: String
        let discourse: CatalogDiscourse
        let seriesInfo: SeriesInfo
        let position: TimeInterval
        let savedDuration: TimeInterval
    }

    private var continueListening: [ContinueItem] {
        playbackState.recentlyPlayed.compactMap { discourseID in
            guard downloads.isDownloaded(discourseID) else { return nil }
            let position = playbackState.getPosition(discourseId: discourseID)
            let savedDuration = playbackState.getDuration(discourseId: discourseID)
            let isCurrentlyPlaying = player.currentTrackId == discourseID

            guard position > 0 || isCurrentlyPlaying else { return nil }

            guard let (disc, series) = Catalog.discourseLookup[discourseID] else { return nil }
            return ContinueItem(
                id: discourseID,
                discourse: disc,
                seriesInfo: series,
                position: isCurrentlyPlaying ? player.currentTime : position,
                savedDuration: isCurrentlyPlaying && player.duration > 0 ? player.duration : savedDuration
            )
        }
        .prefix(8)
        .map { $0 }
    }

    // MARK: - Recently Completed

    struct CompletedItem: Identifiable {
        let id: String
        let discourse: CatalogDiscourse
        let seriesInfo: SeriesInfo
    }

    private var recentlyCompleted: [CompletedItem] {
        playbackState.listenedCompleted.compactMap { discourseID in
            guard let (disc, series) = Catalog.discourseLookup[discourseID] else { return nil }
            return CompletedItem(id: discourseID, discourse: disc, seriesInfo: series)
        }
        .prefix(6)
        .map { $0 }
    }

    private var recentlyCompletedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recently Completed")
                    .font(.title3.bold())
                Spacer()
                Button {
                    withAnimation {
                        for item in recentlyCompleted {
                            playbackState.dismissListenedComplete(discourseId: item.id)
                        }
                    }
                } label: {
                    Text("Clear All")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)

            VStack(spacing: 0) {
                ForEach(recentlyCompleted) { item in
                    NavigationLink(value: item.seriesInfo) {
                        HStack(spacing: 12) {
                            SeriesThumbnailView(name: item.seriesInfo.name, size: 48)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.discourse.displayTitle)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                Text(item.seriesInfo.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.body)

                            Button {
                                withAnimation {
                                    playbackState.dismissListenedComplete(discourseId: item.id)
                                }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .padding(6)
                                    .background(Color.primary.opacity(0.08))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)

                    if item.id != recentlyCompleted.last?.id {
                        Divider().padding(.leading, 68)
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: - Continue Listening

    private var continueListeningSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Continue Listening")
                    .font(.title3.bold())
                Spacer()
                Button {
                    withAnimation {
                        for item in continueListening {
                            playbackState.dismissFromRecent(discourseId: item.id)
                        }
                    }
                } label: {
                    Text("Clear All")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)

            VStack(spacing: 0) {
                ForEach(continueListening.prefix(4)) { item in
                    ContinueListeningRow(item: item, onDismiss: {
                        withAnimation {
                            playbackState.dismissFromRecent(discourseId: item.id)
                        }
                    })
                    if item.id != continueListening.prefix(4).last?.id {
                        Divider().padding(.leading, 68)
                    }
                }
            }
            .padding(.horizontal)
        }
    }
}

// MARK: - Horizontal Section

private struct SeriesSectionView: View {
    let title: String
    let series: [SeriesInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(series) { item in
                        NavigationLink(value: item) {
                            SeriesCardView(series: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

// MARK: - Series Card

private struct SeriesCardView: View {
    let series: SeriesInfo

    var body: some View {
        HStack(spacing: 8) {
            SeriesThumbnailView(name: series.name, size: 36)

            VStack(alignment: .leading, spacing: 1) {
                Text(series.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text("\(series.count) discourses")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Thumbnail View

struct SeriesThumbnailView: View {
    let name: String
    let size: CGFloat

    private var gradientColors: [Color] {
        let hash = abs(name.hashValue)
        let hue1 = Double(hash % 360) / 360.0
        let hue2 = Double((hash / 360) % 360) / 360.0
        return [
            Color(hue: hue1, saturation: 0.6, brightness: 0.5),
            Color(hue: hue2, saturation: 0.7, brightness: 0.3)
        ]
    }

    private var initials: String {
        String(name.prefix(2)).uppercased()
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(
                LinearGradient(
                    colors: gradientColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .overlay {
                Text(initials)
                    .font(.system(size: size * 0.3, weight: .bold))
                    .foregroundStyle(.primary)
            }
    }
}

// MARK: - Continue Listening Row

private struct ContinueListeningRow: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(DownloadService.self) private var downloads
    let item: HomeView.ContinueItem
    var onDismiss: (() -> Void)?

    private var isCurrentlyPlaying: Bool {
        player.currentTrackId == item.discourse.id && player.isPlaying
    }

    private var isCurrentTrack: Bool {
        player.currentTrackId == item.discourse.id
    }

    private var progressFraction: Double {
        let pos = isCurrentTrack ? player.currentTime : item.position
        let dur = isCurrentTrack && player.duration > 0 ? player.duration : item.savedDuration
        guard pos > 0, dur > 0 else { return 0 }
        return min(pos / dur, 1.0)
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                playItem()
            } label: {
                HStack(spacing: 12) {
                    SeriesThumbnailView(name: item.seriesInfo.name, size: 48)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.discourse.displayTitle)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(item.seriesInfo.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.primary.opacity(0.1))
                                    .frame(height: 3)
                                Capsule()
                                    .fill(Color.accent)
                                    .frame(width: geo.size.width * progressFraction, height: 3)
                            }
                        }
                        .frame(height: 3)
                    }
                }
            }
            .buttonStyle(.plain)

            Button { playItem() } label: {
                Image(systemName: isCurrentlyPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accent)
            }
            .buttonStyle(.plain)

            if let onDismiss {
                Button { onDismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .background(Color.primary.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
    }

    private func playItem() {
        if isCurrentTrack {
            player.togglePlayPause()
            return
        }
        guard downloads.localFileURL(for: item.discourse.id) != nil else { return }

        let allDiscourses = Catalog.discourses(for: item.seriesInfo)
        let queueItems = allDiscourses
            .filter { downloads.isDownloaded($0.id) }
            .compactMap { d -> AudioPlayerService.QueueItem? in
                guard let fileURL = downloads.localFileURL(for: d.id) else { return nil }
                return AudioPlayerService.QueueItem(
                    id: d.id,
                    url: fileURL,
                    title: d.displayTitle,
                    series: item.seriesInfo.name
                )
            }

        let startIndex = queueItems.firstIndex { $0.id == item.discourse.id } ?? 0
        player.playQueue(items: queueItems, startIndex: startIndex)
    }
}
