import SwiftUI

struct MiniPlayerView: View {
    @Environment(AudioPlayerService.self) private var player
    @Binding var showFullPlayer: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image("OshoPortrait")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(player.currentTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                Text(player.currentSeries)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            showFullPlayer = true
        }
    }
}
