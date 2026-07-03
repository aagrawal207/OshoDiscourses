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
}
