import SwiftUI

enum WatchRoute: Hashable {
    case remotePlayer
    case localPlayer
    case page(CompanionLocation)
    case offline
    case remoteSpeed
    case localSpeed
}

@MainActor
struct WatchRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var path: [WatchRoute]
    private let session = WatchAppSession.shared

    init() {
        var initial: [WatchRoute] = []
        #if DEBUG
        if let route = WatchAppSession.shared.fixture?.initialRoute(arguments: ProcessInfo.processInfo.arguments) {
            initial = [route]
        }
        #endif
        _path = State(initialValue: initial)
    }

    @ViewBuilder
    private func destination(_ route: WatchRoute) -> some View {
        switch route {
        case .remotePlayer: RemotePlayerView()
        case .localPlayer: LocalPlayerView()
        case .page(let location): CompanionPageView(location: location, path: $path)
        case .offline: OfflineListView(path: $path)
        case .remoteSpeed: RemoteSpeedView()
        case .localSpeed: LocalSpeedView()
        }
    }

    var body: some View {
        let accent = session.model.accent.color
        NavigationStack(path: $path) {
            WatchHomeView()
                // Titles otherwise keep the asset accent instead of the phone's.
                .toolbarForegroundStyle(accent, for: .navigationBar)
                .navigationDestination(for: WatchRoute.self) { route in
                    destination(route)
                        .toolbarForegroundStyle(accent, for: .navigationBar)
                }
        }
        .environment(session.model)
        .environment(session.offline)
        .environment(session.player)
        .tint(accent)
        .transaction { if reduceMotion { $0.animation = nil } }
        #if DEBUG
        .task {
            if path.first == .localPlayer, session.player.current == nil,
               let first = session.offline.entries.first(where: { !$0.finished }) {
                session.player.play(first)
            }
        }
        #endif
        .onChange(of: scenePhase, initial: true) { _, phase in
            session.model.setForeground(phase == .active)
            if phase == .background { session.player.saveNow() }
        }
    }
}

@MainActor
struct WatchHomeView: View {
    @Environment(WatchCompanionModel.self) private var model
    @Environment(OfflineLibrary.self) private var offline
    @Environment(OfflinePlayer.self) private var player

    var body: some View {
        List {
            // Without the phone, saved talks are the only thing that can play, so they lead.
            let savedFirst = !model.connection.canMessage && !offline.entries.isEmpty
            if savedFirst { onWatchSection }
            Section {
                if let current = player.current {
                    NavigationLink(value: WatchRoute.localPlayer) {
                        NowPlayingRow(
                            title: current.title, place: "On Watch", symbol: "applewatch",
                            isPlaying: player.isPlaying
                        )
                    }
                    .accessibilityIdentifier("watch.home.local")
                }
                if let track = model.nowPlaying {
                    NavigationLink(value: WatchRoute.remotePlayer) {
                        NowPlayingRow(
                            title: track.title,
                            place: model.isCurrent ? "On iPhone" : "Last seen on iPhone",
                            symbol: "iphone", isPlaying: model.isPlaying
                        )
                    }
                    .accessibilityIdentifier("watch.home.remote")
                }
                if !model.connection.canMessage || (model.nowPlaying == nil && !model.isCurrent) {
                    ConnectionRow()
                } else if model.nowPlaying == nil {
                    Text("Nothing is playing on iPhone. Choose a talk below.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("watch.home.idle")
                }
                if let notice = model.notice { NoticeRow(message: notice) }
            }
            iPhoneSection
            if !savedFirst { onWatchSection }
        }
        .navigationTitle("Osho Talks")
        .accessibilityIdentifier("watch.home")
    }

    private var iPhoneSection: some View {
        Section("iPhone") {
            LibraryLink(title: "Continue Listening", symbol: "play.circle", location: .continueListening)
            LibraryLink(title: "Downloads", symbol: "arrow.down.circle", location: .downloads)
            LibraryLink(title: "Bookmarks", symbol: "bookmark", location: .bookmarks)
        }
    }

    private var onWatchSection: some View {
        Section("On Watch") {
            NavigationLink(value: WatchRoute.offline) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Saved Talks", systemImage: "applewatch")
                    Text(savedSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .accessibilityIdentifier("watch.home.offline")
        }
    }

    private var savedSummary: String {
        let count = offline.entries.count + model.requestedTransfers.keys.filter { !offline.contains($0) }.count
        guard count > 0 else { return "Nothing saved yet" }
        let talks = offline.entries.count == 1 ? "1 talk" : "\(offline.entries.count) talks"
        let pending = count - offline.entries.count
        if offline.entries.isEmpty { return "Sending from iPhone…" }
        let base = "\(talks) · \(OfflineLibrary.storageLabel(offline.totalBytes))"
        return pending > 0 ? base + " · \(pending) sending" : base
    }
}

private struct LibraryLink: View {
    let title: String
    let symbol: String
    let location: CompanionLocation

    var body: some View {
        NavigationLink(value: WatchRoute.page(location)) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .accessibilityIdentifier("watch.home.\(title)")
    }
}

private struct NowPlayingRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let place: String
    let symbol: String
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isPlaying ? "waveform" : "pause.fill")
                .foregroundStyle(.tint)
                .symbolEffect(.variableColor.iterative, isActive: isPlaying && !reduceMotion)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                Label(place, systemImage: symbol)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isPlaying ? "Playing" : "Paused")
        .accessibilityHint("Opens Now Playing")
    }
}

@MainActor
struct ConnectionRow: View {
    @Environment(WatchCompanionModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(model.connectionTitle, systemImage: model.connectionSymbol)
                .font(.footnote.weight(.semibold))
            Text(model.connectionDetail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("watch.connection")
        if model.canRetryConnection {
            RefreshButton(title: "Try Again")
        }
    }
}

@MainActor
struct RefreshButton: View {
    @Environment(WatchCompanionModel.self) private var model
    var title = "Refresh"

    var body: some View {
        Button {
            Task { await model.refresh() }
        } label: {
            Label(model.isRefreshing ? "Checking…" : title, systemImage: "arrow.clockwise")
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .disabled(model.isRefreshing)
        .accessibilityIdentifier("watch.refresh")
    }
}

@MainActor
struct NoticeRow: View {
    @Environment(WatchCompanionModel.self) private var model
    let message: String

    var body: some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("watch.notice")
        if model.needsReconciliation {
            RefreshButton()
        }
    }
}
