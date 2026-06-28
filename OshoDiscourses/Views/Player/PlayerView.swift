import SwiftUI

struct PlayerView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var isDragging = false
    @State private var dragTime: TimeInterval = 0
    @State private var showSpeedPicker = false
    @State private var showSleepTimer = false
    private var sleepTimer = SleepTimerService.shared
    @State private var showBookmarkSheet = false
    @State private var bookmarkTimestamp: TimeInterval = 0
    @State private var showBookmarkAdded = false
    @State private var showTotalTime = false
    private var bookmarks = BookmarkService.shared

    private var displayTime: TimeInterval {
        isDragging ? dragTime : player.currentTime
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Drag handle
                Capsule()
                    .fill(Color.secondary.opacity(0.5))
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
                        .background(UserSettings.shared.effectiveAccentTheme.color.opacity(0.15))
                        .foregroundStyle(UserSettings.shared.effectiveAccentTheme.color)
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
        }
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
                        .foregroundStyle(UserSettings.shared.effectiveAccentTheme.color)
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
                        // Use seekWithHistory so a large manual scrub surfaces the
                        // "Back to position" button (same as a bookmark jump).
                        player.seekWithHistory(to: dragTime)
                        isDragging = false
                    }
                }
            )
            .tint(UserSettings.shared.effectiveAccentTheme.color)

            HStack {
                Text(formatTime(displayTime))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Spacer()

                Text(showTotalTime
                    ? formatTime(player.duration)
                    : "-\(formatTime(max(player.duration - displayTime, 0)))"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .onTapGesture {
                    showTotalTime.toggle()
                }
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
        HStack(spacing: 0) {
            playerControlButton(
                icon: "speedometer",
                label: formatSpeed(player.playbackRate),
                isActive: player.playbackRate != 1.0
            ) {
                showSpeedPicker.toggle()
            }
            .popover(isPresented: $showSpeedPicker) {
                speedPickerContent
            }

            playerControlButton(
                icon: player.isNoiseReductionEnabled ? "waveform.slash" : "waveform",
                label: "Denoise",
                isActive: player.isNoiseReductionEnabled
            ) {
                player.isNoiseReductionEnabled.toggle()
            }
            .contextMenu {
                Section("Denoise Strength") {
                    ForEach(AudioPlayerService.DenoiseStrength.allCases, id: \.self) { strength in
                        Button {
                            player.denoiseStrength = strength
                            if !player.isNoiseReductionEnabled {
                                player.isNoiseReductionEnabled = true
                            }
                        } label: {
                            if player.denoiseStrength == strength {
                                Label(strength.label, systemImage: "checkmark")
                            } else {
                                Text(strength.label)
                            }
                        }
                    }
                }
            }

            playerControlButton(
                icon: player.volume > 1.0 ? "speaker.wave.3.fill" : "speaker.wave.2",
                label: "Boost",
                isActive: player.volume > 1.0
            ) {
                player.setVolume(player.volume > 1.0 ? 1.0 : 1.5)
            }

            playerControlButton(
                icon: sleepTimer.isActive ? "moon.fill" : "moon",
                label: sleepTimer.statusLabel,
                isActive: sleepTimer.isActive
            ) {
                showSleepTimer.toggle()
            }
            .popover(isPresented: $showSleepTimer) {
                sleepTimerContent
            }

            playerControlButton(
                icon: "bookmark",
                label: "Bookmark",
                isActive: false
            ) {
                bookmarkTimestamp = player.currentTime
                showBookmarkSheet = true
            }
        }
    }

    private func playerControlButton(icon: String, label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .frame(height: 22)
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundStyle(isActive ? UserSettings.shared.effectiveAccentTheme.color : .secondary)
        }
        .buttonStyle(.plain)
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
            Button {
                sleepTimer.startUntilEndOfDiscourse()
                showSleepTimer = false
            } label: {
                HStack {
                    Text("End of discourse")
                        .font(.body)
                    Spacer()
                    if sleepTimer.mode == .endOfDiscourse {
                        Image(systemName: "checkmark")
                            .font(.caption)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            Divider()

            ForEach([5, 10, 15, 30, 45, 60], id: \.self) { minutes in
                Button {
                    sleepTimer.start(minutes: minutes)
                    showSleepTimer = false
                } label: {
                    HStack {
                        Text("\(minutes) min")
                            .font(.body)
                        Spacer()
                        if sleepTimer.mode == .countdown {
                            let activeMinutes = Int(sleepTimer.remainingTime) / 60 + (Int(sleepTimer.remainingTime) % 60 > 0 ? 1 : 0)
                            if activeMinutes == minutes {
                                Image(systemName: "checkmark")
                                    .font(.caption)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }

            if sleepTimer.isActive {
                Divider()

                Button {
                    sleepTimer.cancel()
                    showSleepTimer = false
                } label: {
                    Text("Cancel")
                        .font(.body)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 160)
        .padding(.vertical, 8)
        .presentationCompactAdaptation(.popover)
    }

    // MARK: - Helpers

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let hrs = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        if hrs > 0 {
            return String(format: "%d:%02d:%02d", hrs, mins, secs)
        }
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
