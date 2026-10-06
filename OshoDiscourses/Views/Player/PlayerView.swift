import SwiftUI

struct PlayerView: View {
    @Environment(AudioPlayerService.self) private var player
    /// Optional so previews and any host without a window model still work.
    @Environment(AppNavigation.self) private var navigation: AppNavigation?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isDragging = false
    @State private var dragTime: TimeInterval = 0
    @State private var showSpeedPicker = false
    @State private var showSleepTimer = false
    @State private var showAudioEnhancement = false
    @State private var showQueue = false
    @State private var showTranscript = false
    /// The wide player's reading pane; the listener's choice persists.
    @AppStorage("player.transcriptPaneVisible") private var showsTranscriptPane = true
    private var sleepTimer = SleepTimerService.shared
    private var transcripts = TranscriptService.shared
    @State private var showBookmarkSheet = false
    @State private var bookmarkTimestamp: TimeInterval = 0
    @State private var showBookmarkAdded = false
    @State private var showTotalTime = false
    /// Whether this window has room for the reading pane beside or below the controls.
    @State private var paneFits = false
    private var bookmarks = BookmarkService.shared

    // Scale the fixed artwork/glyph sizes with Dynamic Type, capped so the
    // layout doesn't blow past the screen at accessibility sizes — the
    // ScrollView below handles anything that still overflows.
    @ScaledMetric(relativeTo: .body) private var artworkSize: CGFloat = 280
    @ScaledMetric(relativeTo: .body) private var playGlyphSize: CGFloat = 64

    private var displayTime: TimeInterval {
        isDragging ? dragTime : player.currentTime
    }

    private var isRegular: Bool { AppLayout.isRegular(sizeClass) }

    private var hasOpenSheet: Bool {
        showQueue || showAudioEnhancement || showTranscript || showBookmarkSheet
    }

    /// How the player uses the space it was given. Phones and narrow windows
    /// keep the single column; regular width reads along beside or below it.
    enum Arrangement: Equatable {
        case single
        case sideBySide
        case stacked
    }

    /// Accessibility text sizes skip the stacked layout: its fixed-height
    /// controls band would need its own scrolling.
    static func arrangement(for size: CGSize, isRegular: Bool, showsTranscript: Bool, largeText: Bool = false) -> Arrangement {
        guard isRegular, showsTranscript else { return .single }
        if size.width >= 900, size.width >= size.height { return .sideBySide }
        if size.height >= 900, !largeText { return .stacked }
        return .single
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let arrangement = Self.arrangement(
                    for: proxy.size,
                    isRegular: isRegular,
                    showsTranscript: hasTranscript && showsTranscriptPane,
                    largeText: dynamicTypeSize.isAccessibilitySize
                )
                Group {
                    switch arrangement {
                    case .single:
                        controlsColumn(size: proxy.size, arrangement: arrangement)
                            .frame(maxWidth: isRegular ? 560 : .infinity)
                            .frame(maxWidth: .infinity)
                    case .sideBySide:
                        let columnWidth = min(max(proxy.size.width * 0.4, 380), 500)
                        HStack(spacing: 0) {
                            controlsColumn(size: CGSize(width: columnWidth, height: proxy.size.height), arrangement: arrangement)
                                .frame(width: columnWidth)
                            Divider()
                            transcriptPane
                        }
                    case .stacked:
                        // Enough for the controls with a 260pt cover; the reader gets the rest.
                        let controlsHeight = min(max(proxy.size.height * 0.46, 540), 620)
                        VStack(spacing: 0) {
                            controlsColumn(size: CGSize(width: min(proxy.size.width, 640), height: controlsHeight), arrangement: arrangement)
                                .frame(maxWidth: 640, maxHeight: controlsHeight)
                                .frame(maxWidth: .infinity)
                            Divider()
                            transcriptPane
                        }
                    }
                }
                .onChange(of: navigation?.wantsTranscript) { _, _ in consumeTranscriptRequest() }
                .onChange(of: proxy.size, initial: true) { _, size in
                    paneFits = Self.arrangement(
                        for: size, isRegular: isRegular, showsTranscript: true, largeText: dynamicTypeSize.isAccessibilitySize
                    ) != .single
                    consumeTranscriptRequest()
                }
            }
            .background(Color(.systemBackground))
            .background {
                if isRegular {
                    EscapeKeyHandler { if navigation?.canClosePlayer ?? true { closePlayer() } }
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
            }
        }
        .presentationDragIndicator(.hidden)
        .onAppear(perform: consumeBookmarkRequest)
        .onChange(of: hasOpenSheet, initial: true) { _, open in navigation?.isPlayerCovered = open }
        .onDisappear { navigation?.isPlayerCovered = false }
        .onChange(of: navigation?.pendingBookmark) { _, _ in consumeBookmarkRequest() }
        .sheet(isPresented: $showQueue) {
            // Re-injected for the same reason as the full player in ContentView:
            // a sheet gets a fresh PresentationHostingController whose graph
            // doesn't inherit @Observable objects on macOS, so QueueView's
            // @Environment(AudioPlayerService.self) would trap.
            QueueView()
                .environment(player)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showAudioEnhancement) {
            NavigationStack {
                AudioEnhancementView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showAudioEnhancement = false }
                                .accessibilityIdentifier("audioEnhancement.done")
                        }
                    }
            }
            .environment(player)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            // A dense settings page; the default iPad form sheet cut it off at the boost row.
            .presentationSizing(.page)
        }
        .sheet(isPresented: $showTranscript) {
            if let id = player.currentTrackId {
                TranscriptView(discourseID: id)
                    .environment(player)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showBookmarkSheet) {
            if let id = player.currentTrackId {
                AddBookmarkSheet(
                    timestamp: bookmarkTimestamp,
                    discourseID: id,
                    seriesName: player.currentSeries,
                    title: player.currentTitle
                ) {
                    showBookmarkAdded = true
                }
                .presentationDetents([.medium])
            }
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

    // MARK: - Columns

    /// Artwork, track info and transport. `size` is the space this column
    /// owns, which in the wide layouts is less than the whole window.
    private func controlsColumn(size: CGSize, arrangement: Arrangement) -> some View {
        // GeometryReader + minHeight keeps the Spacer()-driven layout
        // identical when everything fits (default text size), while the
        // ScrollView keeps the transport controls reachable once Dynamic
        // Type pushes the column taller than the screen.
        let artwork = artworkEdge(in: size, arrangement: arrangement)
        let sidePadding: CGFloat = size.width < 380 ? 16 : 24
        let tight = size.height < 700 || arrangement == .stacked
        return ScrollView {
            VStack(spacing: 0) {
                if !isRegular {
                    // Drag handle
                    Capsule()
                        .fill(Color.secondary.opacity(0.5))
                        .frame(width: 36, height: 5)
                        .padding(.top, 8)
                        .accessibilityHidden(true)
                }

                // Top row: close (full-window player), output route (AirPlay) + Up Next queue
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
                transportControls(width: size.width - sidePadding * 2)
                    .padding(.top, tight ? 12 : 24)

                // Bottom controls
                bottomControls(arrangement: arrangement)
                    .padding(.top, tight ? 16 : 32)

                if player.isNoiseReductionEnabled, player.audioProcessingStatus.isIssue {
                    Text(player.audioProcessingStatus.label)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                }

                Spacer()
            }
            .padding(.horizontal, sidePadding)
            .frame(minHeight: size.height)
        }
    }

    @ViewBuilder
    private var transcriptPane: some View {
        if let id = player.currentTrackId {
            TranscriptView(discourseID: id, presentation: .embedded)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("player.transcriptPane")
        }
    }

    /// Menu and keyboard requests to read along.
    private func consumeTranscriptRequest() {
        guard let navigation, navigation.wantsTranscript else { return }
        navigation.wantsTranscript = false
        guard hasTranscript else { return }
        if paneFits { showsTranscriptPane = true } else { showTranscript = true }
    }

    private func closePlayer() {
        if let navigation { navigation.isPlayerPresented = false } else { dismiss() }
    }

    private func consumeBookmarkRequest() {
        guard let navigation, let draft = navigation.pendingBookmark else { return }
        navigation.pendingBookmark = nil
        guard draft.discourseID == player.currentTrackId else { return }
        bookmarkTimestamp = draft.timestamp
        showBookmarkSheet = true
    }

    // MARK: - Artwork

    /// Artwork is the one elastic block in the column, so it takes the leftover
    /// space rather than a fixed 280pt. Capped by width on narrow phones and by
    /// height in the short iPad form sheet — the old width-only cap is what
    /// clipped the bottom row and forced scrolling on iPad.
    private func artworkEdge(in size: CGSize, arrangement: Arrangement) -> CGFloat {
        // A full iPad window has room for a larger cover than the phone's 280pt.
        let preferred = isRegular ? max(artworkSize, 400) : artworkSize
        if arrangement == .stacked {
            // The rest of the column needs about 340pt at default text size.
            return max(150, min(260, preferred, size.height - 340))
        }
        return max(150, min(preferred, size.width - 48, size.height * 0.34))
    }

    private func artworkView(edge: CGFloat) -> some View {
        Image("OshoPortrait")
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: edge, height: edge)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .white.opacity(0.08), radius: 30)
            .accessibilityHidden(true)
            // Lyrics-style shortcut: the artwork is the biggest tap target on
            // the screen, so it opens the transcript when there is one.
            .onTapGesture { if hasTranscript, !(paneFits && showsTranscriptPane) { openTranscript() } }
    }

    /// oshoworld.com publishes a transcript for the playing discourse.
    private var hasTranscript: Bool {
        guard let id = player.currentTrackId else { return false }
        return transcripts.availability(for: id) != .unavailable
    }

    /// The wide player opens its reading pane; elsewhere the transcript sheet.
    private func openTranscript() {
        if paneFits {
            showsTranscriptPane.toggle()
        } else {
            showTranscript = true
        }
    }

    // MARK: - Top Bar (AirPlay + Up Next)

    private var topBar: some View {
        HStack(spacing: 8) {
            if isRegular {
                // The full-window player has no swipe-down, so it closes here or with Escape.
                Button {
                    closePlayer()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("Close player")
                .accessibilityIdentifier("player.close")
            }

            AirPlayRoutePicker(tintColor: UIColor(UserSettings.shared.effectiveAccentTheme.color))
                .frame(width: 44, height: 44)
                .accessibilityLabel("AirPlay and output device")

            Spacer()

            Button {
                showQueue = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.title3)
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .hoverEffect(.highlight)
            .accessibilityLabel("Up Next")
            .accessibilityHint("Shows the playback queue")
            .disabled(player.queue.count <= 1)
            .opacity(player.queue.count <= 1 ? 0.35 : 1)
        }
    }

    // MARK: - Track Info

    /// Resolved from the track id through the catalog's dictionary rather than
    /// by scanning 259 series for a name match, so the discourse number and the
    /// series metadata both come straight from the catalog.
    private var currentEntry: (discourse: CatalogDiscourse, series: SeriesInfo)? {
        guard let id = player.currentTrackId else { return nil }
        return Catalog.discourseLookup[id]
    }

    /// "Discourse 1 · Pune, 1976", composed by SeriesMetadata so the place and
    /// year handling is unit tested rather than living inside the view.
    private var discourseSubtitle: String? {
        guard let entry = currentEntry else { return nil }
        return SeriesMetadata.discourseSubtitle(
            number: entry.discourse.number,
            seriesName: entry.series.name
        )
    }

    private var trackInfo: some View {
        VStack(spacing: 4) {
            // The series name leads, with the discourse number and where and
            // when it was recorded underneath. The old layout titled the track
            // "<series> - #N" and then repeated the series name directly below,
            // spending two lines to say the same thing twice.
            seriesTitle

            if let discourseSubtitle {
                Text(discourseSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var seriesTitle: some View {
        let name = player.currentSeries.isEmpty
            ? (player.currentTitle.isEmpty ? "Not Playing" : player.currentTitle)
            : player.currentSeries

        if let series = currentEntry?.series {
            Button {
                if let navigation {
                    navigation.openSeries(series)
                } else {
                    dismiss()
                }
            } label: {
                // Primary rather than accent now that it is the title; the
                // chevron carries the "opens the series" affordance instead.
                HStack(spacing: 4) {
                    Text(name)
                        .font(.title3.bold())
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(name)
            .accessibilityHint("Opens the series")
        } else {
            Text(name)
                .font(.title3.bold())
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
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
                if !player.isPlaying { ReviewRequestService.listenerDidPause() }
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    // Scaled with Dynamic Type but clamped to the real width so
                    // the row still fits at accessibility sizes.
                    .font(.system(size: max(44, min(playGlyphSize, width * 0.18))))
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("player.playPause")

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

    private func bottomControls(arrangement: Arrangement) -> some View {
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
                icon: player.audioProcessingStatus.isIssue ? "exclamationmark.triangle" : "waveform",
                label: "DeNoise",
                isActive: player.audioProcessingStatus.isActive
            ) {
                showAudioEnhancement = true
            }
            .accessibilityLabel("DeNoise")
            .accessibilityValue(player.noiseReductionAccessibilityValue)
            .accessibilityHint("Adjusts noise reduction, quiet speech and volume boost")
            .accessibilityIdentifier("player.audioEnhancement")

            playerControlButton(icon: "doc.plaintext", label: "Transcript", isActive: arrangement != .single) {
                openTranscript()
            }
            .accessibilityValue(paneFits ? (arrangement != .single ? "Shown" : "Hidden") : "")
            .accessibilityLabel("Transcript")
            .accessibilityHint(hasTranscript ? "Reads along with the playing audio" : "No transcript for this discourse")
            .accessibilityIdentifier("player.transcript")
            .disabled(!hasTranscript)
            .opacity(hasTranscript ? 1 : 0.35)

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
        // Short control labels must fit five columns on narrow screens.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
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
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 4)
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
