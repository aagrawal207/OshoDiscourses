import SwiftUI

@main
struct OshoDiscoursesApp: App {
    @State private var audioPlayer = AudioPlayerService()
    @State private var downloadService = DownloadService()
    @State private var playbackState = PlaybackStateService()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(audioPlayer)
                .environment(downloadService)
                .environment(playbackState)
                .onChange(of: scenePhase) { _, newPhase in
                    // Returning to the foreground: reclaim the audio session and
                    // refresh Now Playing so Control Center / Lock Screen / AirPods
                    // controls come back if iOS handed focus away while backgrounded.
                    if newPhase == .active {
                        audioPlayer.handleForegroundReturn()
                        // The day may have rolled over while backgrounded; refresh
                        // the shuffled accent so it advances without a relaunch.
                        UserSettings.shared.refreshShuffledTheme()
                        // Control Center controls wrote a one-shot request; act on
                        // it exactly once. `.open` just needs the app foreground
                        // (nothing more to do); `.resume` starts playback here —
                        // audio can only run in the app, not the widget extension.
                        if ControlHandoff.consumePendingAction() == .resume {
                            resumeMostRecentDiscourse()
                        }
                    }
                }
                .onAppear {
                    playbackState.attach(to: audioPlayer)
                    audioPlayer.playbackStateService = playbackState
                    audioPlayer.downloadService = downloadService
                    SleepTimerService.shared.onExpire = { [weak audioPlayer] in
                        guard let audioPlayer, audioPlayer.isPlaying else { return }
                        audioPlayer.togglePlayPause()
                    }
                    // Silent iCloud sync of listening activity (positions, completed,
                    // bookmarks, daily stats) through the user's own iCloud (no
                    // account, no toggle). Push on each local save / bookmark change,
                    // pull/merge on external change.
                    playbackState.onProgressSaved = { CloudSyncService.shared.push() }
                    BookmarkService.shared.onBookmarksChanged = { CloudSyncService.shared.push() }
                    downloadService.onDownloadHistoryChanged = { CloudSyncService.shared.push() }
                    CloudSyncService.shared.start(playbackState: playbackState, downloadService: downloadService)
                }
        }
    }

    /// Start (or resume) the listener's most-recent discourse — the action behind
    /// the Control Center "Resume Discourse" control. Mirrors Home's Continue
    /// Listening: only downloaded discourses are playable, and playback runs the
    /// whole downloaded series so it can auto-advance. No-op if nothing qualifies.
    @MainActor
    private func resumeMostRecentDiscourse() {
        // Most-recent played discourse that is actually on disk.
        guard let id = playbackState.recentlyPlayed.first(where: { downloadService.isDownloaded($0) }),
              let series = Catalog.discourseLookup[id]?.series
        else { return }

        // Already loaded — just resume rather than restart.
        if audioPlayer.currentTrackId == id {
            if !audioPlayer.isPlaying { audioPlayer.togglePlayPause() }
            return
        }

        let queueItems = Catalog.discourses(for: series)
            .filter { downloadService.isDownloaded($0.id) }
            .compactMap { d -> AudioPlayerService.QueueItem? in
                guard let url = downloadService.localFileURL(for: d.id) else { return nil }
                return AudioPlayerService.QueueItem(id: d.id, url: url, title: d.displayTitle, series: series.name)
            }
        guard let startIndex = queueItems.firstIndex(where: { $0.id == id }) else { return }
        audioPlayer.playQueue(items: queueItems, startIndex: startIndex)
    }
}
