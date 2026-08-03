import SwiftUI

/// Minimal app delegate whose only job is the background-download handoff:
/// when a transfer finishes while the app isn't running, iOS relaunches the
/// app in the background and hands us a completion handler here. We must hold
/// it until the recreated URLSession has delivered all its queued events
/// (BackgroundDownloadDelegate.urlSessionDidFinishEvents calls it), otherwise
/// iOS penalizes the app's future background time.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var backgroundSessionCompletionHandler: (() -> Void)?

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        Self.backgroundSessionCompletionHandler = completionHandler
    }
}

@main
struct OshoDiscoursesApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var audioPlayer = AudioPlayerService()
    @State private var downloadService = DownloadService()
    @State private var playbackState = PlaybackStateService()
    @State private var showingSplash = true
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
            ContentView()
                .environment(audioPlayer)
                .environment(downloadService)
                .environment(playbackState)
                .onChange(of: scenePhase) { _, newPhase in
                    // Returning to the foreground: reclaim the audio session and
                    // refresh Now Playing so Lock Screen / AirPods controls come
                    // back if iOS handed focus away while backgrounded.
                    if newPhase == .active {
                        audioPlayer.handleForegroundReturn()
                        // The day may have rolled over while backgrounded; refresh
                        // the shuffled accent so it advances without a relaunch.
                        UserSettings.shared.refreshShuffledTheme()
                    }
                }
                .onAppear {
                    // Prewarm the ~190KB ArchiveCatalog JSON decode off the
                    // main thread so the first thumbnail render doesn't pay it
                    // (static let init is thread-safe; first toucher decodes).
                    Task.detached(priority: .utility) { _ = ArchiveCatalog.mappedSeriesCount }
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

            // A one-shot launch splash laid over ContentView (which mounts
            // underneath at t=0, so all .onAppear wiring and the .onChange
            // scenePhase resume handoff fire on their normal schedule — the
            // splash gates nothing functional). It fades away after ~1s.
            if showingSplash {
                LaunchView { showingSplash = false }
                    .transition(.opacity)
                    .zIndex(1)
            }
            }
            .animation(.easeOut(duration: 0.25), value: showingSplash)
        }
    }
}
