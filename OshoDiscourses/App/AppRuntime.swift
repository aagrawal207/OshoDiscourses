import Foundation

/// Process-owned services shared by every scene: the phone/iPad/Mac windows,
/// CarPlay and the Watch connection. A CarPlay-only launch never shows a window,
/// so all wiring happens here rather than in a view's `onAppear`.
@MainActor
final class AppRuntime {
    static let shared = AppRuntime()

    let audioPlayer: AudioPlayerService
    let downloadService: DownloadService
    let playbackState: PlaybackStateService
    let launcher: PlaybackLauncher
    let library: CompanionLibrary

    private var didStart = false

    private init() {
        audioPlayer = AudioPlayerService()
        downloadService = DownloadService()
        playbackState = PlaybackStateService()
        launcher = PlaybackLauncher(player: audioPlayer, downloads: downloadService, bookmarks: .shared)
        library = CompanionLibrary(
            downloads: downloadService, playbackState: playbackState, bookmarks: .shared, player: audioPlayer
        )
    }

    /// Idempotent; called from `App.init` before any scene connects.
    func start() {
        guard !didStart else { return }
        didStart = true
        let audioPlayer = audioPlayer
        let downloadService = downloadService
        let playbackState = playbackState

        // Prewarm the ArchiveCatalog JSON decode off the main thread so the first
        // thumbnail render doesn't pay it (static let init is thread-safe).
        Task.detached(priority: .utility) { _ = ArchiveCatalog.mappedSeriesCount }
        playbackState.attach(to: audioPlayer)
        audioPlayer.playbackStateService = playbackState
        audioPlayer.downloadService = downloadService
        // setPlaying also stops a next talk that is still loading after auto-advance.
        SleepTimerService.shared.onExpire = { [weak audioPlayer] in audioPlayer?.setPlaying(false) }
        // Silent iCloud sync through the user's own iCloud: push on each local
        // save or bookmark change, pull and merge on external change.
        playbackState.onProgressSaved = { CloudSyncService.shared.push() }
        BookmarkService.shared.onBookmarksChanged = { CloudSyncService.shared.push() }
        downloadService.onDownloadHistoryChanged = { CloudSyncService.shared.push() }
        TranscriptStateService.shared.onChanged = { CloudSyncService.shared.push() }
        CloudSyncService.shared.start(playbackState: playbackState, downloadService: downloadService)
        // Transcripts travel with the audio: fetched behind each committed
        // download, dropped with a deleted one, backfilled for older downloads.
        downloadService.onDownloadCommitted = { TranscriptService.shared.prefetch($0.id) }
        downloadService.onDownloadDeleted = { TranscriptService.shared.remove($0) }
        Task {
            try? await Task.sleep(for: .seconds(5))
            TranscriptService.shared.backfill(
                downloadedIDs: Array(downloadService.downloadedIDs),
                allowsCellular: UserSettings.shared.allowCellularDownloads
            )
        }
    }
}
