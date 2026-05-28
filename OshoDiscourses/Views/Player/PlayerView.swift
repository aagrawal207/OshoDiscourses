import SwiftUI

struct PlayerView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var isDragging = false
    @State private var dragTime: TimeInterval = 0
    @State private var showSpeedPicker = false
    @State private var showSleepTimer = false
    @State private var showBookmarkSheet = false
    @State private var bookmarkTimestamp: TimeInterval = 0
    @State private var showBookmarkAdded = false
    private var bookmarks = BookmarkService.shared

    private var displayTime: TimeInterval {
        isDragging ? dragTime : player.currentTime
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Drag handle
                Capsule()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 36, height: 5)
                    .padding(.top, 8)

                Spacer()

                // Artwork
                artworkView

                Spacer()

                // Track info
                trackInfo

                // Return to position button
                if player.hasPreviousPosition {
                    Button {
                        player.returnToPreviousPosition()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.caption)
                            Text("Back to \(formatTime(player.previousPosition ?? 0))")
                                .font(.caption.weight(.medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.blue.opacity(0.15))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
                    }
                    .padding(.top, 12)
                }

                // Seek slider
                seekSlider
                    .padding(.top, 24)

                // Transport controls
                transportControls
                    .padding(.top, 24)

                // Bottom controls
                bottomControls
                    .padding(.top, 32)

                Spacer()
            }
            .padding(.horizontal, 24)
            .background(Color(.systemBackground))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDragIndicator(.hidden)
        .sheet(isPresented: $showBookmarkSheet) {
            AddBookmarkSheet(
                timestamp: bookmarkTimestamp,
                discourseID: player.currentTrackId ?? "",
                seriesName: player.currentSeries,
                title: player.currentTitle
            ) {
                showBookmarkAdded = true
            }
            .presentationDetents([.medium])
        }
        .overlay(alignment: .top) {
            if showBookmarkAdded {
                Text("Bookmarked at \(formatTime(bookmarkTimestamp))")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .padding(.top, 60)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onAppear {
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            withAnimation { showBookmarkAdded = false }
                        }
                    }
            }
        }
        .animation(.easeInOut, value: showBookmarkAdded)
    }

    // MARK: - Artwork

    private var artworkView: some View {
        Image("OshoPortrait")
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 280, height: 280)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .white.opacity(0.08), radius: 30)
    }

    // MARK: - Track Info

    private var currentSeriesInfo: SeriesInfo? {
        Catalog.allSeries.first { $0.name == player.currentSeries }
    }

    private var trackInfo: some View {
        VStack(spacing: 4) {
            Text(player.currentTitle.isEmpty ? "Not Playing" : player.currentTitle)
                .font(.title3.bold())
                .lineLimit(2)
                .multilineTextAlignment(.center)

            if currentSeriesInfo != nil {
                Button {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        NotificationCenter.default.post(
                            name: .navigateToSeries,
                            object: currentSeriesInfo
                        )
                    }
                } label: {
                    Text(player.currentSeries)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.blue)
                }
            } else {
                Text(player.currentSeries.isEmpty ? "—" : player.currentSeries)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Seek Slider

    private var seekSlider: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { displayTime },
                    set: { newValue in
                        isDragging = true
                        dragTime = newValue
                    }
                ),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    if !editing {
                        player.seek(to: dragTime)
                        isDragging = false
                    }
                }
            )
            .tint(.white)

            HStack {
                Text(formatTime(displayTime))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Spacer()

                Text("-\(formatTime(max(player.duration - displayTime, 0)))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Transport Controls

    private var transportControls: some View {
        HStack(spacing: 40) {
            // Previous
            Button {
                player.skipToPrevious()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title2)
            }
            .disabled(!player.hasPrevious && player.currentTime <= 3)

            // Skip back
            Button {
                player.skipBackward()
            } label: {
                Image(systemName: "gobackward.15")
                    .font(.title2)
            }

            // Play/Pause
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
            }

            // Skip forward
            Button {
                player.skipForward()
            } label: {
                Image(systemName: "goforward.30")
                    .font(.title2)
            }

            // Next
            Button {
                player.skipToNext()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title2)
            }
            .disabled(!player.hasNext)
        }
        .foregroundStyle(.primary)
    }

    // MARK: - Bottom Controls

    private var bottomControls: some View {
        HStack {
            // Speed
            Button {
                showSpeedPicker.toggle()
            } label: {
                Text(formatSpeed(player.playbackRate))
                    .font(.subheadline.bold())
                    .frame(width: 50, height: 36)
                    .background(Color.primary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .popover(isPresented: $showSpeedPicker) {
                speedPickerContent
            }

            Spacer()

            // Bookmark
            Button {
                bookmarkTimestamp = player.currentTime
                showBookmarkSheet = true
            } label: {
                Image(systemName: "bookmark.fill")
                    .font(.title3)
                    .frame(width: 44, height: 36)
            }
            .foregroundStyle(.primary.opacity(0.7))

            Spacer()

            // Sleep timer
            Button {
                showSleepTimer.toggle()
            } label: {
                Image(systemName: "moon.fill")
                    .font(.title3)
                    .frame(width: 44, height: 36)
            }
            .foregroundStyle(.primary.opacity(0.7))
            .popover(isPresented: $showSleepTimer) {
                sleepTimerContent
            }

            Spacer()

            // Voice boost
            Button {
                let current = player.volume
                if current > 1.0 {
                    player.setVolume(1.0)
                } else {
                    player.setVolume(1.5)
                }
            } label: {
                Image(systemName: player.volume > 1.0 ? "speaker.wave.3.fill" : "speaker.wave.1.fill")
                    .font(.title3)
                    .frame(width: 50, height: 36)
                    .background(player.volume > 1.0 ? Color.blue.opacity(0.2) : Color.primary.opacity(0.1))
                    .foregroundStyle(player.volume > 1.0 ? .blue : .primary.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .foregroundStyle(.primary)
    }

    // MARK: - Speed Picker

    private var speedPickerContent: some View {
        VStack(spacing: 4) {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { speed in
                Button {
                    player.setRate(Float(speed))
                    showSpeedPicker = false
                } label: {
                    HStack {
                        Text(formatSpeed(Float(speed)))
                            .font(.body)
                        Spacer()
                        if abs(Double(player.playbackRate) - speed) < 0.01 {
                            Image(systemName: "checkmark")
                                .font(.caption)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 160)
        .padding(.vertical, 8)
        .presentationCompactAdaptation(.popover)
    }

    // MARK: - Sleep Timer

    private var sleepTimerContent: some View {
        VStack(spacing: 4) {
            ForEach([5, 10, 15, 30, 45, 60], id: \.self) { minutes in
                Button {
                    // Sleep timer would be implemented in a separate service
                    showSleepTimer = false
                } label: {
                    Text("\(minutes) min")
                        .font(.body)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }

            Divider()

            Button {
                showSleepTimer = false
            } label: {
                Text("Off")
                    .font(.body)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 140)
        .padding(.vertical, 8)
        .presentationCompactAdaptation(.popover)
    }

    // MARK: - Helpers

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func formatSpeed(_ speed: Float) -> String {
        if speed == 1.0 { return "1x" }
        if speed == Float(Int(speed)) {
            return "\(Int(speed))x"
        }
        return String(format: "%.2gx", speed)
    }
}
