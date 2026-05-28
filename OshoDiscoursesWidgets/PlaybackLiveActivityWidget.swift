import ActivityKit
import SwiftUI
import WidgetKit

struct PlaybackLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PlaybackAttributes.self) { context in
            // Lock screen / banner view
            lockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded region
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.blue.opacity(0.3))
                            .frame(width: 40, height: 40)
                            .overlay {
                                Image(systemName: "waveform")
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                            }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(context.state.title)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .lineLimit(1)

                            Text(context.attributes.seriesName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: 16) {
                        Button(intent: PlaybackSkipBackIntent()) {
                            Image(systemName: "gobackward.15")
                                .font(.body)
                        }
                        .tint(.white)

                        Button(intent: PlaybackToggleIntent()) {
                            Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title3)
                        }
                        .tint(.white)

                        Button(intent: PlaybackSkipForwardIntent()) {
                            Image(systemName: "goforward.30")
                                .font(.body)
                        }
                        .tint(.white)
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 4) {
                        ProgressView(
                            value: context.state.elapsedSeconds,
                            total: max(context.state.durationSeconds, 1)
                        )
                        .tint(.blue)

                        HStack {
                            Text(formatTime(context.state.elapsedSeconds))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()

                            Spacer()

                            Text("-\(formatTime(max(context.state.durationSeconds - context.state.elapsedSeconds, 0)))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                HStack(spacing: 5) {
                    Image("OshoPortrait")
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    Text("#\(context.state.trackNumber)")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                }
            } compactTrailing: {
                HStack(spacing: 3) {
                    Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.blue)
                    Text(formatTime(max(context.state.durationSeconds - context.state.elapsedSeconds, 0)))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } minimal: {
                Image("OshoPortrait")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 24, height: 24)
                    .clipShape(Circle())
            }
        }
    }

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<PlaybackAttributes>) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.blue.opacity(0.2))
                .frame(width: 48, height: 48)
                .overlay {
                    Image(systemName: "waveform")
                        .foregroundStyle(.blue)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(context.state.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text(context.attributes.seriesName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 12) {
                Button(intent: PlaybackToggleIntent()) {
                    Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                }
                .tint(.white)

                Button(intent: PlaybackSkipForwardIntent()) {
                    Image(systemName: "goforward.30")
                        .font(.body)
                }
                .tint(.white)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
