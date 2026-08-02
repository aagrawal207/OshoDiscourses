import SwiftUI

struct PlayerView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var isDragging = false
    @State private var dragTime: TimeInterval = 0
    @State private var showSpeedPicker = false
    @State private var showSleepTimer = false
    @State private var showDenoisePicker = false
    @State private var showQueue = false
    private var sleepTimer = SleepTimerService.shared
    @State private var showBookmarkSheet = false
    @State private var bookmarkTimestamp: TimeInterval = 0
    @State private var showBookmarkAdded = false
    @State private var showTotalTime = false
    private var bookmarks = BookmarkService.shared

    // Scale the fixed artwork/glyph sizes with Dynamic Type, capped so the
    // layout doesn't blow past the screen at accessibility sizes — the
    // ScrollView below handles anything that still overflows.
    @ScaledMetric(relativeTo: .body) private var artworkSize: CGFloat = 280
    @ScaledMetric(relativeTo: .body) private var playGlyphSize: CGFloat = 64

    private var displayTime: TimeInterval {
        isDragging ? dragTime : player.currentTime
    }

    var body: some View {
        NavigationStack {
            // GeometryReader + minHeight keeps the Spacer()-driven layout
            // identical when everything fits (default text size), while the
            // ScrollView keeps the transport controls reachable once Dynamic
            // Type pushes the column taller than the screen.
            GeometryReader { proxy in
                // The column is sized from the space actually available: a
                // 375pt phone and the ~580x650pt iPad form sheet both used to
                // overflow because artwork, paddings and the transport row were
                // all fixed. Artwork absorbs the slack; paddings tighten when
                // the sheet is short.
                let artwork = artworkEdge(in: proxy.size)
                let sidePadding: CGFloat = proxy.size.width < 380 ? 16 : 24
                let tight = proxy.size.height < 700
                ScrollView {
                    VStack(spacing: 0) {
                        // Drag handle
                        Capsule()
                            .fill(Color.secondary.opacity(0.5))
                            .frame(width: 36, height: 5)
                            .padding(.top, 8)
                            .accessibilityHidden(true)

                        // Top row: output route (AirPlay) + Up Next queue
                        topBar
                            .padding(.top, 8)

                        Spacer()

                        // Artwork
                        artworkView(edge: artwork)

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
                            .padding(.top, tight ? 12 : 24)

                        // Transport controls
                        transportControls(width: proxy.size.width - sidePadding * 2)
                            .padding(.top, tight ? 12 : 24)

                        // Bottom controls
                        bottomControls
                            .padding(.top, tight ? 16 : 32)

                        Spacer()
                    }
                    .padding(.horizontal, sidePadding)
                    .frame(minHeight: proxy.size.height)
                }
            }
            .background(Color(.systemBackground))
        }
        .presentationDragIndicator(.hidden)
        .sheet(isPresented: $showQueue) {
            // Re-injected for the same reason as the full player in ContentView:
            // a sheet gets a fresh PresentationHostingController whose graph
            // doesn't inherit @Observable objects on macOS, so QueueView's
            // @Environment(AudioPlayerService.self) would trap.
            QueueView()
                .environment(player)
                .presentationDetents([.medium, .large])
        }
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

    /// Artwork is the one elastic block in the column, so it takes the leftover
    /// space rather than a fixed 280pt. Capped by width on narrow phones and by
    /// height in the short iPad form sheet — the old width-only cap is what
    /// clipped the bottom row and forced scrolling on iPad.
    private func artworkEdge(in size: CGSize) -> CGFloat {
        max(150, min(artworkSize, size.width - 48, size.height * 0.34))
    }

    private func artworkView(edge: CGFloat) -> some View {
        Image("OshoPortrait")
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: edge, height: edge)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .white.opacity(0.08), radius: 30)
            .accessibilityHidden(true)
    }

    // MARK: - Top Bar (AirPlay + Up Next)

    private var topBar: some View {
        HStack {
            AirPlayRoutePicker(tintColor: UIColor(UserSettings.shared.effectiveAccentTheme.color))
                .frame(width: 40, height: 40)
                .accessibilityLabel("AirPlay and output device")

            Spacer()

            Button {
                showQueue = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.title3)
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 40)
            }
            .accessibilityLabel("Up Next")
            .accessibilityHint("Shows the playback queue")
            .disabled(player.queue.count <= 1)
            .opacity(player.queue.count <= 1 ? 0.35 : 1)
        }
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
                    // Only record the scrubbed value; don't infer drag state here.
                    // SwiftUI also calls this setter as the thumb tracks playback,
                    // so flipping isDragging here would stick it true and freeze
                    // the label until the player was reopened. Drag start/end is
                    // owned solely by onEditingChanged.
                    get: { displayTime },
                    set: { dragTime = $0 }
                ),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    if editing {
                        dragTime = player.currentTime
                        isDragging = true
                    } else {
                        // Use seekWithHistory so a large manual scrub surfaces the
                        // "Back to position" button (same as a bookmark jump).
                        player.seekWithHistory(to: dragTime)
                        isDragging = false
                    }
                }
            )
            .tint(UserSettings.shared.effectiveAccentTheme.color)
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(formatTime(displayTime)) of \(formatTime(player.duration))")

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
                // The toggle is a bare tap gesture on a Text — surface it to
                // VoiceOver as a button so the mode switch is reachable.
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(showTotalTime ? "Total time" : "Time remaining")
                .accessibilityValue(showTotalTime
                    ? formatTime(player.duration)
                    : formatTime(max(player.duration - displayTime, 0))
                )
                .accessibilityHint("Switches between time remaining and total time")
                .accessibilityAction {
                    showTotalTime.toggle()
                }
            }
        }
    }

    // MARK: - Transport Controls

    private func transportControls(width: CGFloat) -> some View {
        // Spacers, not a fixed 40pt gap. Five glyphs plus 4x40pt needed ~324pt
        // of the 327pt available on a 375pt phone, and since this row then
        // defined the column's width it dragged the slider, the time labels and
        // the bottom row off-screen with it.
        HStack(spacing: 0) {
            // Previous
            Button {
                player.skipToPrevious()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title2)
            }
            .disabled(!player.hasPrevious && player.currentTime <= 3)
            .accessibilityLabel("Previous")

            Spacer(minLength: 8)

            // Skip back
            Button {
                player.skipBackward()
            } label: {
                Image(systemName: "gobackward.15")
                    .font(.title2)
            }
            .accessibilityLabel("Skip back 15 seconds")

            Spacer(minLength: 8)

            // Play/Pause
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    // Scaled with Dynamic Type but clamped to the real width so
                    // the row still fits at accessibility sizes.
                    .font(.system(size: max(44, min(playGlyphSize, width * 0.18))))
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Spacer(minLength: 8)

            // Skip forward
            Button {
                player.skipForward()
            } label: {
                Image(systemName: "goforward.30")
                    .font(.title2)
            }
            .accessibilityLabel("Skip forward 30 seconds")

            Spacer(minLength: 8)

            // Next
            Button {
                player.skipToNext()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title2)
            }
            .disabled(!player.hasNext)
            .accessibilityLabel("Next")
        }
        .frame(maxWidth: .infinity)
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
            .accessibilityLabel("Playback speed")
            .accessibilityValue(formatSpeed(player.playbackRate))

            playerControlButton(
                icon: player.isNoiseReductionEnabled ? "waveform.slash" : "waveform",
                label: denoiseButtonLabel,
                isActive: player.isNoiseReductionEnabled
            ) {
                showDenoisePicker.toggle()
            }
            .popover(isPresented: $showDenoisePicker) {
                denoisePickerContent
            }
            .accessibilityLabel("Denoise")
            .accessibilityValue(
                player.isNoiseReductionEnabled
                    ? "On, \(player.noiseReductionMode.displayName), \(player.denoiseStrength.label)"
                    : "Off"
            )

            playerControlButton(
                icon: player.volume > 1.0 ? "speaker.wave.3.fill" : "speaker.wave.2",
                label: player.volume > 1.0 ? "2×" : "Boost",
                isActive: player.volume > 1.0
            ) {
                player.setVolume(player.volume > 1.0 ? 1.0 : 2.0)
            }
            .accessibilityLabel("Volume boost")
            .accessibilityValue(player.volume > 1.0 ? "On, two times" : "Off")
            .accessibilityHint("Increases volume above the system maximum")

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
            .accessibilityLabel("Sleep timer")
            .accessibilityValue(sleepTimer.isActive ? sleepTimer.statusLabel : "Off")

            playerControlButton(
                icon: "bookmark",
                label: "Bookmark",
                isActive: false
            ) {
                bookmarkTimestamp = player.currentTime
                showBookmarkSheet = true
            }
            .accessibilityLabel("Add bookmark")
            .accessibilityHint("Saves the current position")
        }
    }

    private func playerControlButton(icon: String, label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .frame(height: 22)
                Text(label)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
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

    // MARK: - Denoise Picker

    private var denoisePickerContent: some View {
        VStack(spacing: 4) {
            // Beta banner: results vary by recording, and the picker is where
            // the user actually engages the feature — set expectations here,
            // not just in Settings.
            HStack(spacing: 6) {
                Text("Noise Reduction")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("BETA")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.accent.opacity(0.15), in: Capsule())
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 2)

            // Off row — the toggle that used to be the whole control.
            Button {
                player.isNoiseReductionEnabled = false
                showDenoisePicker = false
            } label: {
                HStack {
                    Text("Off")
                        .font(.body)
                    Spacer()
                    if !player.isNoiseReductionEnabled {
                        Image(systemName: "checkmark")
                            .font(.caption)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            Divider()

            ForEach(NoiseReductionMode.allCases) { mode in
                Button {
                    player.noiseReductionMode = mode
                    player.isNoiseReductionEnabled = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.displayName)
                                .font(.body)
                            // For DeepFilterNet, show live state once selected —
                            // the model loads asynchronously, so "Loading…" or an
                            // error is more useful than a static description.
                            Text(statusDescriptor(for: mode))
                                .font(.caption)
                                .foregroundStyle(
                                    mode == player.noiseReductionMode && player.isDeepFilterBypassing
                                        ? .orange
                                        : .secondary
                                )
                        }
                        Spacer()
                        if player.isNoiseReductionEnabled, player.noiseReductionMode == mode {
                            Image(systemName: "checkmark")
                                .font(.caption)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }

            Divider()

            // DeepFilterNet is always fully wet, so a dry/wet "strength" does
            // not apply. It gets the voice-forward variants instead, switchable
            // mid-discourse so they can be compared on the same passage.
            if player.noiseReductionMode == .deepFilterNet {
                ForEach(VoiceFocusPreset.allCases) { preset in
                    Button {
                        player.voiceFocusPreset = preset
                        player.isNoiseReductionEnabled = true
                    } label: {
                        HStack {
                            Text(preset.displayName)
                                .font(.body)
                            Spacer()
                            if player.isNoiseReductionEnabled, player.voiceFocusPreset == preset {
                                Image(systemName: "checkmark")
                                    .font(.caption)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                ForEach(AudioPlayerService.DenoiseStrength.allCases, id: \.self) { strength in
                    Button {
                        player.denoiseStrength = strength
                        player.isNoiseReductionEnabled = true
                        showDenoisePicker = false
                    } label: {
                        HStack {
                            Text(strength.label)
                                .font(.body)
                            Spacer()
                            if player.isNoiseReductionEnabled, player.denoiseStrength == strength {
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
        }
        .frame(width: 220)
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

    /// Player button caption. While comparing DeepFilterNet variants the active
    /// preset matters more than the processor name, so show that instead.
    private var denoiseButtonLabel: String {
        guard player.isNoiseReductionEnabled else { return "Denoise" }
        if player.noiseReductionMode == .deepFilterNet {
            return player.voiceFocusPreset.displayName
        }
        return player.noiseReductionMode.playerLabel
    }

    /// Subtitle for a processor row. DeepFilterNet reports its real runtime state
    /// while selected so a listener never assumes audio is being processed when
    /// the model is still loading or failed to load.
    private func statusDescriptor(for mode: NoiseReductionMode) -> String {
        guard mode == .deepFilterNet,
              player.isNoiseReductionEnabled,
              player.noiseReductionMode == .deepFilterNet else {
            return mode.shortDescriptor
        }
        return player.deepFilterStatus.label
    }

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
