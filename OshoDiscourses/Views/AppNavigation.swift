import SwiftUI

/// Top-level destinations. Raw values are stable identifiers for UI tests and
/// must not be renamed; titles are what the tab bar and sidebar show.
enum AppTab: String, Hashable, CaseIterable, Identifiable {
    case home, library, downloads, settings, bookmarks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .library: "Library"
        case .downloads: "Downloads"
        case .settings: "Settings"
        case .bookmarks: "Bookmarks"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house.fill"
        case .library: "books.vertical"
        case .downloads: "arrow.down.circle"
        case .settings: "gearshape"
        case .bookmarks: "bookmark"
        }
    }

    /// ⌘1…⌘4 follow the tab bar order; Bookmarks (⌘5) is sidebar-only.
    static let shortcutOrder: [AppTab] = [.home, .library, .downloads, .settings]
}

/// A bookmark captured at the moment it was asked for, so the time does not
/// drift while the sheet animates in.
struct BookmarkDraft: Identifiable, Equatable {
    let id = UUID()
    let discourseID: String
    let seriesName: String
    let title: String
    let timestamp: TimeInterval
}

/// Per-window navigation. Each scene owns one, so two iPad or Mac windows
/// browse independently while sharing the single process-wide player.
@MainActor
@Observable
final class AppNavigation {
    var selectedTab: AppTab = .home
    var isPlayerPresented = false
    /// A sheet is open over the player, so Escape belongs to that sheet.
    var isPlayerCovered = false
    /// Consumed by the presented player: reveal the transcript pane or sheet.
    var wantsTranscript = false
    var pendingBookmark: BookmarkDraft?
    /// Consumed by Home's stack, which pushes the series page.
    var pendingSeries: SeriesInfo?

    private var player: AudioPlayerService { AppRuntime.shared.audioPlayer }

    var hasTrack: Bool { player.currentTrackId != nil }

    var canShowTranscript: Bool {
        guard let id = player.currentTrackId else { return false }
        return TranscriptService.shared.availability(for: id) != .unavailable
    }

    func select(_ tab: AppTab) {
        isPlayerPresented = false
        // Bookmarks is a sidebar destination; phones reach it through Downloads.
        selectedTab = tab == .bookmarks && UIDevice.current.userInterfaceIdiom == .phone ? .downloads : tab
    }

    func showPlayer() {
        guard hasTrack else { return }
        isPlayerPresented = true
    }

    var canClosePlayer: Bool { isPlayerPresented && !isPlayerCovered }

    func closePlayer() {
        guard canClosePlayer else { return }
        isPlayerPresented = false
    }

    func showTranscript() {
        guard canShowTranscript else { return }
        wantsTranscript = true
        isPlayerPresented = true
    }

    func addBookmark() {
        guard let id = player.currentTrackId else { return }
        pendingBookmark = BookmarkDraft(
            discourseID: id,
            seriesName: player.currentSeries,
            title: player.currentTitle,
            timestamp: player.currentTime
        )
    }

    func openSeries(_ series: SeriesInfo) {
        isPlayerPresented = false
        selectedTab = .home
        pendingSeries = series
    }
}

/// What the menus need to enable and label their items. Published as a value
/// so menus rebuild when it changes; command bodies do not observe models.
struct CommandState: Equatable {
    var hasTrack = false
    var isPlaying = false
    var hasNext = false
    var rate: Float = 1
    var sleepMode: SleepTimerService.Mode = .off
    var canShowTranscript = false
    var isPlayerPresented = false
    var canClosePlayer = false
}

extension FocusedValues {
    /// The key window's navigation, so menu and keyboard commands act on the
    /// window the listener is using.
    @Entry var appNavigation: AppNavigation?
    @Entry var commandState: CommandState?
}

/// Width rules shared by the tab roots. Compact width is the phone layout and
/// must not move; regular width is a full-screen or wide iPad window, or Mac.
enum AppLayout {
    /// Lists of rows stop here: a row stretched across 1000pt strands its
    /// title far from its buttons.
    static let listMaxWidth: CGFloat = 720
    /// Grids and wide headers can use more of the window.
    static let gridMaxWidth: CGFloat = 1100
    /// Mini player column when it floats over regular-width content.
    static let floatingMaxWidth: CGFloat = 560
    static let gridMinimumCardWidth: CGFloat = 260

    /// Large iPhones report regular width in landscape; they keep the phone
    /// layout, which is designed and tested for that idiom.
    @MainActor static func isRegular(_ sizeClass: UserInterfaceSizeClass?) -> Bool {
        sizeClass == .regular && UIDevice.current.userInterfaceIdiom != .phone
    }

    /// Horizontal margin that centres a column of `maxWidth` in `width`.
    static func centeringMargin(in width: CGFloat, maxWidth: CGFloat, minimum: CGFloat = 16) -> CGFloat {
        guard width.isFinite, width > 0 else { return minimum }
        return max(minimum, (width - maxWidth) / 2)
    }
}

extension View {
    /// Centres a scroll view's content in a readable column on regular width;
    /// compact width keeps the system margins untouched.
    func readableScrollColumn(_ sizeClass: UserInterfaceSizeClass?, maxWidth: CGFloat = AppLayout.listMaxWidth) -> some View {
        modifier(ReadableScrollColumn(isRegular: AppLayout.isRegular(sizeClass), maxWidth: maxWidth))
    }
}

private struct ReadableScrollColumn: ViewModifier {
    let isRegular: Bool
    let maxWidth: CGFloat
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        if isRegular {
            // Safe-area padding rather than content margins: inset-grouped lists
            // resolve content margins against the sidebar's inset unpredictably.
            content
                .safeAreaPadding(.horizontal, AppLayout.centeringMargin(in: width, maxWidth: maxWidth, minimum: 0))
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        } else {
            content
        }
    }
}
