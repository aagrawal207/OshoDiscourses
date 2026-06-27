import SwiftUI

struct ContentView: View {
    @Environment(AudioPlayerService.self) private var player
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
                        Label("My Activity", systemImage: "person.crop.circle")
                    }
                    .tag(2)

                SettingsView()
                    .tabItem {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .tag(3)
            }
            .tint(settings.accentTheme.color)

            if player.currentTrackId != nil {
                MiniPlayerView(showFullPlayer: $showFullPlayer)
                    .padding(.bottom, 56)
            }
        }
        .sheet(isPresented: $showFullPlayer) {
            PlayerView()
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
