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
    private let runtime: AppRuntime
    @State private var audioPlayer: AudioPlayerService
    @State private var downloadService: DownloadService
    @State private var playbackState: PlaybackStateService
    @State private var showingSplash = true
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let runtime = AppRuntime.shared
        runtime.start()
        WatchPhoneSession.shared.start(runtime: runtime)
        MacWindowConfigurator.install()
        self.runtime = runtime
        _audioPlayer = State(initialValue: runtime.audioPlayer)
        _downloadService = State(initialValue: runtime.downloadService)
        _playbackState = State(initialValue: runtime.playbackState)
    }

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

            // A one-shot launch splash laid over ContentView, which mounts
            // underneath at t=0; the splash gates nothing functional.
            if showingSplash {
                LaunchView { showingSplash = false }
                    .transition(.opacity)
                    .zIndex(1)
            }
            }
            .animation(.easeOut(duration: 0.25), value: showingSplash)
        }
        .commands { AppCommands(player: audioPlayer) }
    }
}
