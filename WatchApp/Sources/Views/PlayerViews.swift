import SwiftUI

/// Shared Now Playing layout for the iPhone remote and the watch's own player. Transport sits
/// directly under the title so it fits the first viewport on 40 mm; extras scroll below.
struct PlayerLayout<Secondary: View>: View {
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    let title: String
    let series: String
    let duration: Double
    let isPlaying: Bool
    let isBusy: Bool
    let canControl: Bool
    /// Whether elapsed time advances on its own between updates.
    let interpolates: Bool
    let status: String
    let sleepLabel: String?
    let playLabel: String
    let pauseLabel: String
    let elapsed: () -> Double
    let onBack: () -> Void
    let onToggle: () -> Void
    let onForward: () -> Void
    @ViewBuilder let secondary: () -> Secondary

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(2)
                        .accessibilityIdentifier("watch.player.title")
                    Text(series)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)

                transport

                TimelineView(.animation(minimumInterval: 1, paused: !interpolates || isLuminanceReduced)) { _ in
                    progress(elapsed())
                }

                statusText
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .accessibilityLabel(sleepLabel.map { "\(status). Sleep timer, \($0)" } ?? status)
                    .accessibilityIdentifier("watch.player.status")

                secondary()
            }
            .padding(.horizontal, 4)
        }
    }

    private var statusText: Text {
        guard let sleepLabel else { return Text(status) }
        return Text("\(status) · \(Image(systemName: "moon.zzz")) \(sleepLabel)")
    }

    private var transport: some View {
        HStack(spacing: 0) {
            Button(action: onBack) {
                Image(systemName: "gobackward.15")
                    .font(.title3)
                    .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Skip back 15 seconds")
            .accessibilityIdentifier("watch.player.back")

            Button(action: onToggle) {
                ZStack {
                    Circle().fill(.tint)
                    if isBusy {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.black)
                            // The play triangle's visual centre sits left of its frame.
                            .offset(x: isPlaying ? 0 : 1)
                    }
                }
                .frame(width: 52, height: 52)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(canControl ? 1 : 0.45)
            .accessibilityLabel(isPlaying ? pauseLabel : playLabel)
            .accessibilityValue(isBusy ? "Waiting" : "")
            .accessibilityIdentifier("watch.player.playPause")

            Button(action: onForward) {
                Image(systemName: "goforward.30")
                    .font(.title3)
                    .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Skip forward 30 seconds")
            .accessibilityIdentifier("watch.player.forward")
        }
        .disabled(!canControl)
    }

    private func progress(_ position: Double) -> some View {
        VStack(spacing: 2) {
            ProgressView(value: duration > 0 ? min(position / duration, 1) : 0)
                .accessibilityHidden(true)
            HStack {
                Text(WatchTime.timestamp(position))
                Spacer(minLength: 4)
                Text(WatchTime.remaining(position, duration: duration))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Elapsed")
        .accessibilityValue(duration > 0
            ? "\(WatchTime.spoken(position)) of \(WatchTime.spoken(duration))"
            : WatchTime.spoken(position))
        .accessibilityIdentifier("watch.player.progress")
    }
}

/// Small round button for the secondary row; the label keeps a 44-point target.
struct SecondaryControl<Label: View>: View {
    let accessibilityLabel: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

@MainActor
struct RemotePlayerView: View {
    @Environment(WatchCompanionModel.self) private var model
    @Environment(OfflinePlayer.self) private var localPlayer

    var body: some View {
        Group {
            if let displayed = model.timeline.snapshot, let track = displayed.nowPlaying {
                player(track, displayed: displayed)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Nothing playing")
                            .font(.headline)
                        Text("Choose a talk from Continue Listening or Downloads.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if !model.connection.canMessage { ConnectionRow() }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("watch.player.empty")
            }
        }
        .navigationTitle("iPhone")
    }

    private func player(_ track: CompanionNowPlaying, displayed: CompanionSnapshot) -> some View {
        let pending = model.pendingCommand != nil
        let status: String = if pending {
            "Sending to iPhone…"
        } else if !model.isCurrent {
            "Last seen on iPhone"
        } else {
            // The navigation title already names the iPhone.
            track.isPlaying ? "Playing" : "Paused"
        }
        return PlayerLayout(
            title: track.title, series: track.series, duration: track.duration,
            isPlaying: model.isCurrent && track.isPlaying,
            isBusy: pending && [.setPlaying(true), .setPlaying(false)].contains(model.pendingCommand?.action),
            canControl: model.canControl, interpolates: model.isPlaying,
            status: status, sleepLabel: track.sleepTimerLabel,
            playLabel: "Play on iPhone", pauseLabel: "Pause on iPhone",
            elapsed: { model.position },
            onBack: { send(.skipBackward, displayed) },
            onToggle: {
                if !track.isPlaying, localPlayer.isPlaying { localPlayer.pause() }
                send(.setPlaying(!track.isPlaying), displayed)
            },
            onForward: { send(.skipForward, displayed) }
        ) {
            HStack(spacing: 0) {
                SecondaryControl(accessibilityLabel: "Previous talk", action: { send(.previousDiscourse, displayed) }) {
                    Image(systemName: "backward.end.fill")
                }
                .disabled(!model.canControl || !track.hasPrevious)
                .accessibilityIdentifier("watch.player.previous")

                NavigationLink(value: WatchRoute.remoteSpeed) {
                    Text(WatchTime.rateLabel(track.rate))
                        .font(.footnote.weight(.semibold).monospacedDigit())
                        .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.canControl)
                .accessibilityLabel("Playback speed")
                .accessibilityValue(WatchTime.rateLabel(track.rate))
                .accessibilityIdentifier("watch.player.speed")

                SecondaryControl(accessibilityLabel: "Next talk", action: { send(.nextDiscourse, displayed) }) {
                    Image(systemName: "forward.end.fill")
                }
                .disabled(!model.canControl || !track.hasNext)
                .accessibilityIdentifier("watch.player.next")
            }
            if let notice = model.notice {
                NoticeRow(message: notice)
            } else if !model.isCurrent {
                if model.connection.canMessage { RefreshButton() } else { ConnectionRow() }
            }
        }
        .accessibilityIdentifier("watch.player.remote")
    }

    private func send(_ action: CompanionAction, _ displayed: CompanionSnapshot) {
        Task { await model.command(action, displayed: displayed) }
    }
}

@MainActor
struct LocalPlayerView: View {
    @Environment(OfflinePlayer.self) private var player

    var body: some View {
        Group {
            if let entry = player.current {
                PlayerLayout(
                    title: entry.title, series: entry.series, duration: player.duration,
                    isPlaying: player.isPlaying, isBusy: player.isActivating, canControl: true,
                    interpolates: false,
                    status: player.isActivating ? "Connecting headphones…" : player.isPlaying ? "Playing" : "Paused",
                    sleepLabel: nil, playLabel: "Play", pauseLabel: "Pause",
                    elapsed: { player.elapsed },
                    onBack: { player.skip(by: -15) },
                    onToggle: { player.togglePlayPause() },
                    onForward: { player.skip(by: 30) }
                ) {
                    NavigationLink(value: WatchRoute.localSpeed) {
                        Label(WatchTime.rateLabel(player.rate), systemImage: "speedometer")
                            .font(.footnote.weight(.semibold).monospacedDigit())
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Playback speed")
                    .accessibilityValue(WatchTime.rateLabel(player.rate))
                    .accessibilityIdentifier("watch.local.speed")
                    if let error = player.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("watch.local.error")
                    }
                }
                .accessibilityIdentifier("watch.player.local")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Nothing playing").font(.headline)
                    Text(player.errorMessage ?? "Choose a saved talk to play it on Apple Watch.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle("Watch")
    }
}

@MainActor
struct RemoteSpeedView: View {
    @Environment(WatchCompanionModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SpeedList(selected: model.nowPlaying?.rate ?? 1, enabled: model.canControl) { rate in
            guard let displayed = model.timeline.snapshot else { return }
            Task {
                await model.command(.setRate(rate), displayed: displayed)
                dismiss()
            }
        }
    }
}

@MainActor
struct LocalSpeedView: View {
    @Environment(OfflinePlayer.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SpeedList(selected: player.rate, enabled: true) { rate in
            player.setRate(rate)
            dismiss()
        }
    }
}

private struct SpeedList: View {
    let selected: Float
    let enabled: Bool
    let choose: (Float) -> Void

    var body: some View {
        List(OfflinePlayer.rates, id: \.self) { rate in
            Button {
                choose(rate)
            } label: {
                HStack {
                    Text(WatchTime.rateLabel(rate)).monospacedDigit()
                    Spacer()
                    if rate == selected {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .disabled(!enabled)
            .accessibilityAddTraits(rate == selected ? .isSelected : [])
        }
        .navigationTitle("Speed")
    }
}
