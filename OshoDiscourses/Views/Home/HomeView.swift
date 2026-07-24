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
            // Grouped background (light gray in light mode, true black in dark)
            // so the section cards below read as distinct blocks. Fixes the
            // boundary-less look where headings floated on one flat backdrop.
            .background(Color(.systemGroupedBackground))
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
            // Deliberately use only the saved position/duration here. Reading
            // player.currentTime/duration would invalidate the whole Home body
            // every 0.5s during playback; ContinueListeningRow already reads
            // the live values itself for the current track.
            return ContinueItem(
                id: discourseID,
                discourse: disc,
                seriesInfo: series,
                position: position,
                savedDuration: savedDuration
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
                        // Grow the hit area to 44pt without enlarging the text.
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal)

            VStack(spacing: 0) {
                ForEach(recentlyCompleted) { item in
                    NavigationLink(value: item.seriesInfo) {
                        HStack(spacing: 12) {
                            SeriesThumbnailView(name: item.seriesInfo.name, size: 48, seriesID: item.seriesInfo.id)

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
                                    // 44pt hit area; the small circular glyph stays as-is.
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove from Recently Completed")
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
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
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
                        // Grow the hit area to 44pt without enlarging the text.
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
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
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
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
            SeriesThumbnailView(name: series.name, size: 36, seriesID: series.id)

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
    /// Series id for Archive.org cover art lookup. Optional: nil (or an
    /// unmapped id) keeps the gradient+initials look. Covers load through
    /// CoverArtLoader (memory + disk cached, downsampled) — a cached cover
    /// paints on the row's first frame with no placeholder flash.
    var seriesID: String? = nil

    /// Seeded synchronously from the memory cache so a recycled lazy row
    /// renders its cover immediately instead of flashing initials first.
    @State private var cover: UIImage?

    init(name: String, size: CGFloat, seriesID: String? = nil) {
        self.name = name
        self.size = size
        self.seriesID = seriesID
        _cover = State(initialValue: seriesID.flatMap { CoverArtLoader.cachedImage(for: $0) })
    }

    /// FNV-1a over the name's UTF-8 bytes. Swift's String.hashValue is randomly
    /// seeded per launch, which shuffled every gradient on each app start —
    /// this keeps a series' colors stable across launches (and devices).
    private static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    private var gradientColors: [Color] {
        let hash = Self.stableHash(name)
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
                // The archive "cover" is a waveform PNG: black strokes on a
                // TRANSPARENT background, so whatever is underneath shows
                // through. The initials must therefore only exist while
                // there's no artwork — in light mode .primary initials are
                // black, and black letters bleeding through a black waveform
                // was an unreadable smudge (dark mode masked it: white
                // letters read as backlight). Waveform-over-gradient renders
                // identically in both modes.
                if let cover {
                    Image(uiImage: cover)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        // The 4:1 waveform lays out wider than the frame;
                        // clipShape clips drawing but NOT hit-testing — keep
                        // the overflow from swallowing taps near the row.
                        .allowsHitTesting(false)
                } else {
                    Text(initials)
                        .font(.system(size: size * 0.3, weight: .bold))
                        .foregroundStyle(.primary)
                }
            }
            // Purely decorative (waveform art or initials); the row's text
            // carries the series name for VoiceOver.
            .accessibilityHidden(true)
            .task(id: seriesID) {
                guard cover == nil, let seriesID else { return }
                cover = await CoverArtLoader.image(for: seriesID)
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
                    SeriesThumbnailView(name: item.seriesInfo.name, size: 48, seriesID: item.seriesInfo.id)

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
            .accessibilityLabel(isCurrentlyPlaying ? "Pause" : "Play")

            if let onDismiss {
                Button { onDismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .background(Color.primary.opacity(0.08))
                        .clipShape(Circle())
                        // 44pt hit area; the small circular glyph stays as-is.
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove from Continue Listening")
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
