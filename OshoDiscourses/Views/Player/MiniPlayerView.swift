import SwiftUI

struct MiniPlayerView: View {
    @Environment(AudioPlayerService.self) private var player
    @Binding var showFullPlayer: Bool

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
        VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                    Rectangle()
                        .fill(Color.accent)
                        .frame(width: geo.size.width * progressFraction)
                }
            }
            .frame(height: 2.5)

            HStack(spacing: 12) {
                Image("OshoPortrait")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

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

                Spacer()

                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .foregroundStyle(Color.accent)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
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
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the full player")
    }
}
