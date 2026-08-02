import SwiftUI

/// Cap for blocks that would otherwise span the full width of an iPad. A row
/// stretched across 1032pt leaves its title marooned on the far left and its
/// buttons on the far right, which is what made the iPad look stretched. Every
/// iPhone is narrower than this, so the cap is inert there.
let contentMaxWidth: CGFloat = 640

struct ContentView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(DownloadService.self) private var downloads
    @Environment(PlaybackStateService.self) private var playbackState
    @State private var showFullPlayer = false
    @State private var selectedTab = 0
    @Bindable private var settings = UserSettings.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                HomeView()
                    .tabItem {
                        Label("Home", systemImage: "house.fill")
                    }
                    .tag(0)

                LibraryView()
                    .tabItem {
                        Label("Library", systemImage: "books.vertical")
                    }
                    .tag(1)

                DownloadsView()
                    .tabItem {
                        Label("Downloads", systemImage: "arrow.down.circle")
                    }
                    .tag(2)

                SettingsView()
                    .tabItem {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .tag(3)
            }
            .tint(settings.effectiveAccentTheme.color)

            if player.currentTrackId != nil {
                MiniPlayerView(showFullPlayer: $showFullPlayer)
                    .frame(maxWidth: contentMaxWidth)
                    .padding(.bottom, 56)
            }
        }
        .sheet(isPresented: $showFullPlayer) {
            // The services are re-injected here on purpose. Presenting a sheet
            // builds a fresh PresentationHostingController with its own graph
            // host, and on macOS (iOS app on Apple Silicon) that host does not
            // inherit the @Observable objects from the presenting view. The
            // sheet content's @Environment(AudioPlayerService.self) then finds
            // nothing and traps in EnvironmentValues.subscript.getter, so the
            // app hard-crashed when the mini player opened the full player.
            // iPhone happens to inherit correctly; macOS goes via SheetBridge.
            PlayerView()
                .environment(player)
                .environment(downloads)
                .environment(playbackState)
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToSeries)) { _ in
            selectedTab = 0
        }
        .preferredColorScheme(colorSchemeForAppearance(settings.appearance))
    }

    private func colorSchemeForAppearance(_ appearance: UserSettings.Appearance) -> ColorScheme? {
        switch appearance {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }
}
