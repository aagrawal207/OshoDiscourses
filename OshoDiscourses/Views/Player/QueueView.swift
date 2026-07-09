import SwiftUI

/// The playback queue as an Up Next list. Shows what's playing now and what
/// follows, and lets the listener jump straight to any entry. The queue is
/// download-scoped (it's built from downloaded discourses in a series), so this
/// mirrors exactly what will play — no streaming placeholders.
struct QueueView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.dismiss) private var dismiss

    private var accent: Color { UserSettings.shared.effectiveAccentTheme.color }

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(player.queue.enumerated()), id: \.element.id) { index, item in
                    Button {
                        player.playQueueItem(at: index)
                        dismiss()
                    } label: {
                        row(for: item, at: index)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Up Next")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(for item: AudioPlayerService.QueueItem, at index: Int) -> some View {
        let isCurrent = index == player.currentIndex
        return HStack(spacing: 12) {
            // Leading glyph: animated bars for the current item, position number
            // for the rest.
            Group {
                if isCurrent {
                    Image(systemName: player.isPlaying ? "waveform" : "pause.fill")
                        .foregroundStyle(accent)
                        .symbolEffect(.variableColor, isActive: player.isPlaying)
                } else {
                    Text("\(index + 1)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .font(.subheadline)
            .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? accent : .primary)
                    .lineLimit(1)
                Text(item.series)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isCurrent ? "Now playing: \(item.title)" : "\(item.title), \(item.series)")
        .accessibilityHint(isCurrent ? "" : "Plays this discourse")
    }
}
