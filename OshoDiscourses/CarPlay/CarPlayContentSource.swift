#if canImport(CarPlay) && !targetEnvironment(macCatalyst)
import Foundation
import Observation

struct CarPlayQueueEntry: Equatable, Sendable {
    let discourseID: String
    let title: String
    let series: String
}

/// Cancels a change subscription; the next observation fire is dropped.
@MainActor
final class CarPlayObservation {
    private(set) var isCancelled = false
    func cancel() { isCancelled = true }
}

/// Everything CarPlay reads or asks of the phone. The app's implementation wraps
/// `AppRuntime`; tests supply their own so fixtures stay out of the user's stores.
@MainActor
protocol CarPlayContentSource: AnyObject {
    func page(for location: CompanionLocation, maximumRows: Int) -> CompanionPage
    /// Plays a discourse or bookmark row id from `CompanionLibrary`.
    func play(rowID: String) throws(PlaybackLauncher.Failure)

    var currentDiscourseID: String? { get }
    var isPlaying: Bool { get }
    var queue: [CarPlayQueueEntry] { get }
    var currentQueueIndex: Int { get }
    func playQueueItem(at index: Int)

    var playbackRate: Float { get }
    func setRate(_ rate: Float)
    /// Adds a bookmark at the current position; false when nothing is loaded.
    func addBookmarkAtCurrentTime() -> Bool

    /// Calls `onChange` after list-relevant state changes (downloads, recent
    /// playback, bookmarks, current track, queue), never for position ticks.
    func observeChanges(_ onChange: @escaping @MainActor @Sendable () -> Void) -> CarPlayObservation
}

@MainActor
final class CarPlayRuntimeSource: CarPlayContentSource {
    private let library: CompanionLibrary
    private let launcher: PlaybackLauncher
    private let player: AudioPlayerService
    private let downloads: DownloadService
    private let playbackState: PlaybackStateService
    private let bookmarks: BookmarkService

    init(library: CompanionLibrary, launcher: PlaybackLauncher, player: AudioPlayerService,
         downloads: DownloadService, playbackState: PlaybackStateService, bookmarks: BookmarkService) {
        self.library = library
        self.launcher = launcher
        self.player = player
        self.downloads = downloads
        self.playbackState = playbackState
        self.bookmarks = bookmarks
    }

    convenience init(runtime: AppRuntime) {
        self.init(library: runtime.library, launcher: runtime.launcher, player: runtime.audioPlayer,
                  downloads: runtime.downloadService, playbackState: runtime.playbackState, bookmarks: .shared)
    }

    func page(for location: CompanionLocation, maximumRows: Int) -> CompanionPage {
        library.page(for: location, maximumRows: maximumRows)
    }

    func play(rowID: String) throws(PlaybackLauncher.Failure) {
        switch CompanionLibrary.resolve(rowID) {
        case .discourse(let id): try launcher.playDiscourse(id)
        case .bookmark(let id): try launcher.playBookmark(id: id)
        case .series, nil: throw .unknownDiscourse
        }
    }

    var currentDiscourseID: String? { player.currentTrackId }
    var isPlaying: Bool { player.isPlaying }
    var queue: [CarPlayQueueEntry] {
        player.queue.map { CarPlayQueueEntry(discourseID: $0.id, title: $0.title, series: $0.series) }
    }
    var currentQueueIndex: Int { player.currentIndex }
    func playQueueItem(at index: Int) { player.playQueueItem(at: index) }

    var playbackRate: Float { player.playbackRate }
    func setRate(_ rate: Float) { player.setRate(rate) }

    func addBookmarkAtCurrentTime() -> Bool {
        guard let id = player.currentTrackId else { return false }
        let time = player.currentTime.isFinite ? max(0, player.currentTime) : 0
        bookmarks.add(discourseID: id, seriesName: player.currentSeries, title: player.currentTitle, timestamp: time)
        return true
    }

    func observeChanges(_ onChange: @escaping @MainActor @Sendable () -> Void) -> CarPlayObservation {
        let token = CarPlayObservation()
        arm(token, onChange)
        return token
    }

    private func arm(_ token: CarPlayObservation, _ onChange: @escaping @MainActor @Sendable () -> Void) {
        guard !token.isCancelled else { return }
        withObservationTracking {
            // currentTime is deliberately absent: it ticks twice a second.
            _ = downloads.downloadedIDs
            _ = playbackState.recentlyPlayed
            _ = bookmarks.bookmarks
            _ = player.currentTrackId
            _ = player.isPlaying
            _ = player.queue.count
            _ = player.currentIndex
            _ = player.playbackRate
        } onChange: { [weak self, weak token] in
            // Fires in willSet; the hop lets the new value land before anything reads it.
            Task { @MainActor [weak self, weak token] in
                guard let self, let token, !token.isCancelled else { return }
                onChange()
                self.arm(token, onChange)
            }
        }
    }
}
#endif
