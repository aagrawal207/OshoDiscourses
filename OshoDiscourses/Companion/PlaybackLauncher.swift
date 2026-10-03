import Foundation

/// Starts playback by catalog identity, for surfaces that cannot hold a
/// SwiftUI view's environment (CarPlay, the Watch connection, menu commands).
/// Playback stays download-only, matching the phone's series and Home rows.
@MainActor
final class PlaybackLauncher {
    enum Failure: Error, Equatable, Sendable {
        case unknownDiscourse
        case notDownloaded
        case unknownBookmark

        var message: String {
            switch self {
            case .unknownDiscourse: return "This discourse is no longer in the catalog."
            case .notDownloaded: return "Download this discourse on your iPhone first."
            case .unknownBookmark: return "This bookmark was removed."
            }
        }
    }

    private let player: AudioPlayerService
    private let downloads: DownloadService
    private let bookmarks: BookmarkService

    init(player: AudioPlayerService, downloads: DownloadService, bookmarks: BookmarkService) {
        self.player = player
        self.downloads = downloads
        self.bookmarks = bookmarks
    }

    /// The downloaded discourses of the series in catalog order, so auto-play
    /// continues through the series exactly as it does from the series page.
    func seriesQueue(startingAt discourseID: String) throws(Failure) -> (items: [AudioPlayerService.QueueItem], start: Int) {
        guard let entry = Catalog.discourseLookup[discourseID] else { throw .unknownDiscourse }
        guard downloads.localFileURL(for: discourseID) != nil else { throw .notDownloaded }
        let items = Catalog.discourses(for: entry.series).compactMap { d -> AudioPlayerService.QueueItem? in
            guard downloads.isDownloaded(d.id), let url = downloads.localFileURL(for: d.id) else { return nil }
            return AudioPlayerService.QueueItem(id: d.id, url: url, title: d.displayTitle, series: entry.series.name)
        }
        guard let start = items.firstIndex(where: { $0.id == discourseID }) else { throw .notDownloaded }
        return (items, start)
    }

    /// Resumes the current discourse or starts it from its saved position.
    func playDiscourse(_ discourseID: String) throws(Failure) {
        if player.currentTrackId == discourseID {
            if !player.isPlaying { player.resumePlayback() }
            return
        }
        let queue = try seriesQueue(startingAt: discourseID)
        player.playQueue(items: queue.items, startIndex: queue.start)
    }

    func playBookmark(id: String) throws(Failure) {
        guard let bookmark = bookmarks.bookmarks.first(where: { $0.id == id }) else { throw .unknownBookmark }
        if player.currentTrackId == bookmark.discourseID {
            player.seekWithHistory(to: bookmark.timestamp)
            if !player.isPlaying { player.resumePlayback() }
            return
        }
        let queue = try seriesQueue(startingAt: bookmark.discourseID)
        player.playQueue(items: queue.items, startIndex: queue.start, resumeAt: bookmark.timestamp)
    }
}
