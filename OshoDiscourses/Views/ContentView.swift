import SwiftUI
import AVFoundation

/// Cap for blocks that would otherwise span the full width of an iPad. A row
/// stretched across 1032pt leaves its title marooned on the far left and its
/// buttons on the far right. Every iPhone is narrower than this, so the cap is
/// inert there; regular-width screens use `AppLayout` instead.
let contentMaxWidth: CGFloat = 640

struct ContentView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(DownloadService.self) private var downloads
    @Environment(PlaybackStateService.self) private var playbackState
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// One per window: each scene builds its own ContentView.
    @State private var navigation = AppNavigation()
    /// Measured once before the tabs mount: a landscape window opens with the
    /// sidebar beside content, a portrait one with the top tab bar instead of
    /// a sidebar overlay that hides the page.
    @State private var opensWithSidebar: Bool?
    /// Bottom inset a tab's content sees (tab bar plus home indicator) and the
    /// root's own inset; their difference is the tab bar the mini player clears.
    @State private var tabContentBottomInset: CGFloat?
    @State private var rootBottomInset: CGFloat = 0
    @State private var miniPlayerHeight: CGFloat = 64
    @Bindable private var settings = UserSettings.shared
    #if DEBUG
    /// `-debugTranscript <discourseID>` on the launch arguments plays that
    /// (already downloaded) discourse and opens its transcript (or the full
    /// player with `-debugPlayer`), so the reader can be exercised in a
    /// simulator without tapping through the UI.
    @State private var debugTranscriptID: String?
    @State private var showDebugTranscript = false
    #endif

    private var isRegular: Bool { AppLayout.isRegular(sizeClass) }

    /// iOS 26.1 hosts the regular-width mini player in the tab view's own
    /// accessory, which insets content and never covers the sidebar.
    private var usesBottomAccessory: Bool {
        guard isRegular else { return false }
        if #available(iOS 26.1, *) { return true }
        return false
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if let opensWithSidebar {
                tabs
                    .defaultAdaptableTabBarPlacement(opensWithSidebar ? .sidebar : .tabBar)
                    .tint(settings.effectiveAccentTheme.color)
            } else {
                Color.clear
                    .onGeometryChange(for: Bool.self, of: { $0.size.width > $0.size.height }) { wide in
                        if opensWithSidebar == nil { opensWithSidebar = wide }
                    }
            }

            if player.currentTrackId != nil, !usesBottomAccessory {
                MiniPlayerView(showFullPlayer: $navigation.isPlayerPresented)
                    .frame(maxWidth: isRegular ? AppLayout.floatingMaxWidth : contentMaxWidth)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { miniPlayerHeight = $0 }
                    // Phones clear the bottom tab bar, measured since its height varies by
                    // OS and device; regular width has its tabs at the top or in the sidebar.
                    .padding(.bottom, isRegular ? 12 : miniPlayerTabBarClearance)
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.safeAreaInsets.bottom }) { rootBottomInset = $0 }
        .environment(navigation)
        .focusedSceneValue(\.appNavigation, navigation)
        .focusedSceneValue(\.commandState, commandState)
        .sheet(isPresented: compactPlayerBinding) {
            playerScreen
        }
        .fullScreenCover(isPresented: regularPlayerBinding) {
            playerScreen
        }
        .sheet(item: windowBookmarkBinding) { draft in
            AddBookmarkSheet(
                timestamp: draft.timestamp,
                discourseID: draft.discourseID,
                seriesName: draft.seriesName,
                title: draft.title
            ) {}
            .presentationDetents([.medium])
        }
        #if DEBUG
        .task { await runDebugLaunchArguments() }
        .sheet(isPresented: $showDebugTranscript) {
            if let debugTranscriptID {
                TranscriptView(discourseID: debugTranscriptID)
                    .environment(player)
            }
        }
        #endif
        .preferredColorScheme(colorSchemeForAppearance(settings.appearance))
    }

    private var commandState: CommandState {
        CommandState(
            hasTrack: player.currentTrackId != nil,
            isPlaying: player.isPlaying,
            hasNext: player.hasNext,
            rate: player.playbackRate,
            sleepMode: SleepTimerService.shared.mode,
            canShowTranscript: navigation.canShowTranscript,
            isPlayerPresented: navigation.isPlayerPresented,
            canClosePlayer: navigation.canClosePlayer
        )
    }

    /// Space every tab reserves above its bottom edge so the last row can scroll clear of the
    /// floating player. Measured, so it follows Dynamic Type; zero where the tab accessory insets content.
    private var miniPlayerScrollClearance: CGFloat {
        guard player.currentTrackId != nil, !usesBottomAccessory else { return 0 }
        return miniPlayerHeight + (isRegular ? 12 : 6) + 12
    }

    private var miniPlayerTabBarClearance: CGFloat {
        guard let tabContentBottomInset else { return 56 }
        return max(0, tabContentBottomInset - rootBottomInset) + 6
    }

    // MARK: - Tabs

    private var tabs: some View {
        TabView(selection: $navigation.selectedTab) {
            Tab(AppTab.home.title, systemImage: AppTab.home.systemImage, value: AppTab.home) {
                HomeView().environment(\.miniPlayerClearance, miniPlayerScrollClearance)
                    .modifier(TabContentInsetReader(inset: $tabContentBottomInset))
            }
            Tab(AppTab.library.title, systemImage: AppTab.library.systemImage, value: AppTab.library) {
                LibraryView().environment(\.miniPlayerClearance, miniPlayerScrollClearance)
                    .modifier(TabContentInsetReader(inset: $tabContentBottomInset))
            }
            Tab(AppTab.downloads.title, systemImage: AppTab.downloads.systemImage, value: AppTab.downloads) {
                DownloadsView().environment(\.miniPlayerClearance, miniPlayerScrollClearance)
                    .modifier(TabContentInsetReader(inset: $tabContentBottomInset))
            }
            Tab(AppTab.settings.title, systemImage: AppTab.settings.systemImage, value: AppTab.settings) {
                SettingsView().environment(\.miniPlayerClearance, miniPlayerScrollClearance)
                    .modifier(TabContentInsetReader(inset: $tabContentBottomInset))
            }
            // Bookmarks is one tap deep in Downloads on a phone; the sidebar
            // has room to make it a destination of its own. Included only
            // there because `defaultVisibility` still put it in the phone tab bar.
            if isRegular {
                TabSection("Your Listening") {
                    Tab(AppTab.bookmarks.title, systemImage: AppTab.bookmarks.systemImage, value: AppTab.bookmarks) {
                        BookmarksView().environment(\.miniPlayerClearance, miniPlayerScrollClearance)
                    }
                }
                .defaultVisibility(.hidden, for: .tabBar)
            }
        }
        .onChange(of: isRegular) { _, regular in
            if !regular, navigation.selectedTab == .bookmarks { navigation.selectedTab = .downloads }
        }
        .tabViewStyle(.sidebarAdaptable)
        .modifier(BottomAccessoryMiniPlayer(isEnabled: usesBottomAccessory && player.currentTrackId != nil,
                                            showFullPlayer: $navigation.isPlayerPresented))
    }

    // MARK: - Player presentation

    /// Phones keep the swipe-down sheet; regular width gets the full window,
    /// which the two-column player needs.
    private var compactPlayerBinding: Binding<Bool> {
        Binding(
            get: { navigation.isPlayerPresented && !isRegular },
            set: { if !$0 { navigation.isPlayerPresented = false } }
        )
    }

    private var regularPlayerBinding: Binding<Bool> {
        Binding(
            get: { navigation.isPlayerPresented && isRegular },
            set: { if !$0 { navigation.isPlayerPresented = false } }
        )
    }

    /// A bookmark asked for from the menu while the player is closed. With the
    /// player open, the player presents it so the sheet stacks on top.
    private var windowBookmarkBinding: Binding<BookmarkDraft?> {
        Binding(
            get: { navigation.isPlayerPresented ? nil : navigation.pendingBookmark },
            set: { navigation.pendingBookmark = $0 }
        )
    }

    private var playerScreen: some View {
        // The services are re-injected here on purpose. Presenting a sheet
        // builds a fresh PresentationHostingController with its own graph
        // host, and on macOS (iOS app on Apple Silicon) that host does not
        // inherit the @Observable objects from the presenting view. The
        // sheet content's @Environment(AudioPlayerService.self) then finds
        // nothing and traps in EnvironmentValues.subscript.getter.
        PlayerView()
            .environment(player)
            .environment(downloads)
            .environment(playbackState)
            .environment(navigation)
            // Presentations do not inherit the tab view's tint.
            .tint(settings.effectiveAccentTheme.color)
    }

    // MARK: - Debug

    #if DEBUG
    private func runDebugLaunchArguments() async {
        let args = ProcessInfo.processInfo.arguments
        // `-debugDownload <discourseID>` starts a real download through the
        // normal source chain (archive first, then oshoworld) and logs it.
        if let flag = args.firstIndex(of: "-debugDownload"), args.indices.contains(flag + 1),
           let entry = Catalog.discourseLookup[args[flag + 1]] {
            print("[debugDownload] \(entry.discourse.id) oshoworld=\(entry.discourse.audioURL) archive=\(ArchiveCatalog.audioURL(for: entry.discourse)?.absoluteString ?? "none")")
            Task {
                do {
                    let url = try await downloads.download(entry.discourse)
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                    print("[debugDownload] saved \(size) bytes to \(url.lastPathComponent)")
                } catch {
                    print("[debugDownload] failed: \(error)")
                }
            }
        }
        if args.contains("-debugTipJar") { navigation.selectedTab = .settings }
        if let flag = args.firstIndex(of: "-debugTab"), args.indices.contains(flag + 1),
           let tab = AppTab(rawValue: args[flag + 1]) {
            navigation.selectedTab = tab
        }
        // `-debugPlaySample <discourseID>` plays a generated silent recording
        // under that discourse's metadata, so keyboard and transport checks
        // have real playback without a download.
        if let flag = args.firstIndex(of: "-debugPlaySample"), args.indices.contains(flag + 1),
           let entry = Catalog.discourseLookup[args[flag + 1]], let url = DebugSampleAudio.url() {
            player.play(localURL: url, id: entry.discourse.id, title: entry.discourse.displayTitle, series: entry.series.name)
            if args.contains("-debugPlayer") { navigation.isPlayerPresented = true }
            return
        }
        // A paused player makes first-presentation checks independent of audio downloads and timer updates.
        if let flag = args.firstIndex(of: "-debugPlayerDiscourse"), args.indices.contains(flag + 1),
           let entry = Catalog.discourseLookup[args[flag + 1]] {
            player.currentTrackId = entry.discourse.id
            player.currentTitle = entry.discourse.displayTitle
            player.currentSeries = entry.series.name
            if !args.contains("-debugMiniPlayer") { navigation.isPlayerPresented = true }
            return
        }
        guard let flag = args.firstIndex(of: "-debugTranscript"), args.indices.contains(flag + 1) else { return }
        let id = args[flag + 1]
        try? await Task.sleep(for: .seconds(1.5))
        if let entry = Catalog.discourseLookup[id], let url = downloads.localFileURL(for: id) {
            player.play(localURL: url, id: id, title: entry.discourse.displayTitle, series: entry.series.name)
        }
        debugTranscriptID = id
        if args.contains("-debugPlayer") { navigation.isPlayerPresented = true } else { showDebugTranscript = true }
    }
    #endif

    private func colorSchemeForAppearance(_ appearance: UserSettings.Appearance) -> ColorScheme? {
        switch appearance {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }
}

extension EnvironmentValues {
    /// Height a tab's pages reserve for the floating mini-player; zero in sheets and with no player.
    @Entry var miniPlayerClearance: CGFloat = 0
}

extension View {
    /// Apply to each scrolling page, not the tab: a safe-area inset outside a NavigationStack
    /// does not reach the pages it pushes, while the environment value does.
    func reservesMiniPlayerSpace() -> some View {
        modifier(MiniPlayerSpace())
    }
}

private struct MiniPlayerSpace: ViewModifier {
    @Environment(\.miniPlayerClearance) private var clearance

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if clearance > 0 { Color.clear.frame(height: clearance).allowsHitTesting(false) }
        }
    }
}

/// Reports the bottom safe-area inset inside a tab, which includes the tab bar.
private struct TabContentInsetReader: ViewModifier {
    @Binding var inset: CGFloat?

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGFloat.self, of: { $0.safeAreaInsets.bottom }) { value in
            if value > 0 { inset = value }
        }
    }
}

/// Applies the iOS 26.1 tab accessory only where it exists; earlier systems
/// keep the floating capsule in `ContentView`.
private struct BottomAccessoryMiniPlayer: ViewModifier {
    let isEnabled: Bool
    @Binding var showFullPlayer: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: isEnabled) {
                MiniPlayerView(showFullPlayer: $showFullPlayer, style: .accessory)
            }
        } else {
            content
        }
    }
}

#if DEBUG
/// Two minutes of silence written once per launch to the temporary folder.
enum DebugSampleAudio {
    @MainActor static func url() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("debug-sample.caf")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22_050 * 120) else { return nil }
        buffer.frameLength = buffer.frameCapacity
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            return url
        } catch {
            return nil
        }
    }
}
#endif
