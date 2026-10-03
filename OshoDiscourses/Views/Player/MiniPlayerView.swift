import SwiftUI

struct MiniPlayerView: View {
    enum Style {
        /// Its own glass capsule floating over content (iPhone, and iPad before iOS 26.1).
        case floating
        /// Content for `tabViewBottomAccessory`, which supplies the capsule itself.
        case accessory
    }

    @Environment(AudioPlayerService.self) private var player
    @Binding var showFullPlayer: Bool
    var style: Style = .floating

    private var progressFraction: Double {
        guard player.duration > 0 else { return 0 }
        return min(player.currentTime / player.duration, 1.0)
    }

    // The service's `currentTitle` stays "<series> - #N" because that same
    // string feeds the lock screen. Here the number leads and the series name
    // is the subtitle, so the name isn't repeated (and truncated).
    private var seriesLine: String {
        player.currentSeries.isEmpty ? player.currentTitle : player.currentSeries
    }

    private var discourseLine: String? {
        guard !player.currentSeries.isEmpty,
              let hash = player.currentTitle.lastIndex(of: "#") else { return nil }
        let number = player.currentTitle[player.currentTitle.index(after: hash)...]
        guard !number.isEmpty, number.allSatisfy(\.isNumber) else { return nil }
        return "Discourse \(number)"
    }

    var body: some View {
        switch style {
        case .floating: floating
        case .accessory: accessory
        }
    }

    private var floating: some View {
        VStack(spacing: 0) {
            progressBar
                .frame(height: 2.5)

            HStack(spacing: 12) {
                artwork(edge: 44, radius: 6)
                titles
                Spacer()
                playPauseButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            showFullPlayer = true
        }
        .modifier(MiniPlayerAccessibility())
    }

    private var accessory: some View {
        HStack(spacing: 10) {
            artwork(edge: 30, radius: 6)
            titles
            Spacer(minLength: 8)
            playPauseButton
            Button {
                player.skipForward()
            } label: {
                Image(systemName: "goforward.30")
                    .font(.body.weight(.medium))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Skip forward 30 seconds")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        // The accessory capsule has no progress of its own; a hairline along
        // the bottom keeps elapsed time visible without a second bar.
        .overlay(alignment: .bottom) {
            progressBar
                .frame(height: 2)
                .padding(.horizontal, 18)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            showFullPlayer = true
        }
        .modifier(MiniPlayerAccessibility())
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                Rectangle()
                    .fill(Color.accent)
                    .frame(width: geo.size.width * progressFraction)
            }
        }
    }

    private func artwork(edge: CGFloat, radius: CGFloat) -> some View {
        Image("OshoPortrait")
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: edge, height: edge)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(discourseLine ?? seriesLine)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            if discourseLine != nil {
                Text(seriesLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var playPauseButton: some View {
        Button {
            player.togglePlayPause()
        } label: {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.title3)
                .foregroundStyle(Color.accent)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
    }
}

private struct MiniPlayerAccessibility: ViewModifier {
    @Environment(AudioPlayerService.self) private var player

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .combine)
            .accessibilityValue(player.isPlaying ? "Playing" : "Paused")
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens the full player")
            .accessibilityIdentifier("player.mini")
    }
}
