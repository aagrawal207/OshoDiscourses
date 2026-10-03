import Foundation

/// Phone-side lists for CarPlay and the Watch, built from the same services the
/// phone screens use. Row ids are prefixed by kind so `resolve` can route a
/// selection without trusting the remote side's interpretation.
@MainActor
final class CompanionLibrary {
    enum Resolved: Equatable {
        case discourse(String)
        case bookmark(String)
        case series(String)
    }

    private let downloads: DownloadService
    private let playbackState: PlaybackStateService
    private let bookmarks: BookmarkService
    private let player: AudioPlayerService

    init(
        downloads: DownloadService, playbackState: PlaybackStateService,
        bookmarks: BookmarkService, player: AudioPlayerService
    ) {
        self.downloads = downloads
        self.playbackState = playbackState
        self.bookmarks = bookmarks
        self.player = player
    }

    // MARK: Row identity

    nonisolated static func rowID(discourse id: String) -> String { "d:" + id }
    nonisolated static func rowID(bookmark id: String) -> String { "b:" + id }
    nonisolated static func rowID(series id: String) -> String { "s:" + id }

    nonisolated static func resolve(_ rowID: String) -> Resolved? {
        let value = String(rowID.dropFirst(2))
        guard !value.isEmpty else { return nil }
        if rowID.hasPrefix("d:") { return .discourse(value) }
        if rowID.hasPrefix("b:") { return .bookmark(value) }
        if rowID.hasPrefix("s:") { return .series(value) }
        return nil
    }

    // MARK: Lists

    /// Mirrors Home > Continue Listening: downloaded, started or currently loaded.
    func continueListening(limit: Int = 25, watchInventory: Set<String> = []) -> [CompanionRow] {
        var rows: [CompanionRow] = []
        for id in playbackState.recentlyPlayed {
            guard rows.count < limit, downloads.isDownloaded(id),
                  let entry = Catalog.discourseLookup[id] else { continue }
            let position = playbackState.getPosition(discourseId: id)
            guard position > 0 || player.currentTrackId == id else { continue }
            rows.append(discourseRow(entry.discourse, series: entry.series, watchInventory: watchInventory))
        }
        return rows
    }

    func downloadedSeries() -> [CompanionRow] {
        downloads.downloadedDiscourses().map { group in
            let count = group.discourses.count
            return CompanionRow(
                id: Self.rowID(series: group.seriesInfo.id), kind: .series,
                title: group.seriesInfo.name,
                subtitle: count == 1 ? "1 discourse" : "\(count) discourses",
                isCurrent: group.discourses.contains { $0.id == player.currentTrackId }
            )
        }
    }

    func downloadedDiscourses(seriesID: String, watchInventory: Set<String> = []) -> [CompanionRow] {
        guard let series = Catalog.allSeries.first(where: { $0.id == seriesID }) else { return [] }
        return Catalog.discourses(for: series)
            .filter { downloads.isDownloaded($0.id) }
            .map { discourseRow($0, series: series, watchInventory: watchInventory) }
    }

    /// Bookmarks whose discourse is downloaded, newest first.
    func playableBookmarks(limit: Int = 50) -> [CompanionRow] {
        bookmarks.bookmarks
            .filter { downloads.isDownloaded($0.discourseID) }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
            .map { bookmark in
                let note = bookmark.note.trimmingCharacters(in: .whitespacesAndNewlines)
                return CompanionRow(
                    id: Self.rowID(bookmark: bookmark.id), kind: .bookmark,
                    title: note.isEmpty ? bookmark.title : note,
                    subtitle: "\(bookmark.formattedTimestamp) · \(note.isEmpty ? bookmark.seriesName : bookmark.title)",
                    isCurrent: player.currentTrackId == bookmark.discourseID
                )
            }
    }

    func page(for location: CompanionLocation, watchInventory: Set<String> = [], maximumRows: Int = 60) -> CompanionPage {
        let title: String
        let rows: [CompanionRow]
        let empty: String
        switch location {
        case .continueListening:
            title = "Continue Listening"
            rows = continueListening(limit: maximumRows, watchInventory: watchInventory)
            empty = "Talks you start on iPhone appear here."
        case .downloads:
            title = "Downloads"
            rows = downloadedSeries()
            empty = "Download discourses on your iPhone to play them here."
        case .series(let rowOrSeriesID):
            let seriesID: String
            if case .series(let id)? = Self.resolve(rowOrSeriesID) { seriesID = id } else { seriesID = rowOrSeriesID }
            title = Catalog.allSeries.first(where: { $0.id == seriesID })?.name ?? "Series"
            rows = downloadedDiscourses(seriesID: seriesID, watchInventory: watchInventory)
            empty = "No downloaded discourses in this series."
        case .bookmarks:
            title = "Bookmarks"
            rows = playableBookmarks(limit: maximumRows)
            empty = "Bookmarks for downloaded discourses appear here."
        }
        let bounded = Array(rows.prefix(maximumRows))
        return CompanionPage(
            location: location, title: title, rows: bounded,
            isTruncated: bounded.count < rows.count, emptyMessage: empty
        )
    }

    private func discourseRow(_ discourse: CatalogDiscourse, series: SeriesInfo, watchInventory: Set<String>) -> CompanionRow {
        let isCurrent = player.currentTrackId == discourse.id
        let position = isCurrent ? player.currentTime : playbackState.getPosition(discourseId: discourse.id)
        let duration = isCurrent && player.duration > 0 ? player.duration : playbackState.getDuration(discourseId: discourse.id)
        let progress: Double? = duration > 0 && position > 0 ? min(1, position / duration) : nil
        var subtitle = series.name
        if let progress, duration > 0 {
            let remaining = max(0, Int((duration - duration * progress) / 60))
            subtitle = remaining > 0 ? "\(series.name) · \(remaining) min left" : series.name
        }
        return CompanionRow(
            id: Self.rowID(discourse: discourse.id), kind: .discourse,
            title: discourse.displayTitle, subtitle: subtitle,
            progress: progress, isCurrent: isCurrent,
            isOnWatch: watchInventory.contains(discourse.id)
        )
    }

    // MARK: Now Playing

    func nowPlaying() -> CompanionNowPlaying? {
        guard let id = player.currentTrackId else { return nil }
        let sleep = SleepTimerService.shared
        return CompanionNowPlaying(
            discourseID: id, title: player.currentTitle, series: player.currentSeries,
            isPlaying: player.isPlaying, elapsed: player.currentTime.isFinite ? player.currentTime : 0,
            duration: player.duration.isFinite ? player.duration : 0, rate: player.playbackRate,
            hasNext: player.hasNext, hasPrevious: player.hasPrevious,
            sleepTimerLabel: sleep.isActive ? sleep.statusLabel : nil
        )
    }
}
