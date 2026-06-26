import SwiftUI

@main
struct OshoDiscoursesApp: App {
    @State private var audioPlayer = AudioPlayerService()
    @State private var downloadService = DownloadService()
    @State private var playbackState = PlaybackStateService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(audioPlayer)
                .environment(downloadService)
                .environment(playbackState)
                .onAppear {
                    playbackState.attach(to: audioPlayer)
                    audioPlayer.playbackStateService = playbackState
                    audioPlayer.downloadService = downloadService
                    SleepTimerService.shared.onExpire = { [weak audioPlayer] in
                        guard let audioPlayer, audioPlayer.isPlaying else { return }
                        audioPlayer.togglePlayPause()
                    }
                }
        }
    }
}
