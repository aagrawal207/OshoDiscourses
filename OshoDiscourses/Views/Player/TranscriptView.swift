import SwiftUI

/// Full-screen transcript reader that behaves like lyrics: the paragraph being
/// spoken is highlighted and kept in view, the listener can scroll away to read
/// (a pill brings them back), and where they left off is remembered per
/// discourse. Transcripts carry no timestamps of their own; paragraph timing
/// comes from the shipped `AlignmentCatalog`, or on iOS 26 from on-device
/// speech alignment, or failing both from a text-length estimate. The
/// listener's own "Audio is here" anchors correct any of the three.
struct TranscriptView: View {
    /// The discourse to read. Playback controls and the highlight only engage
    /// when this is what the player is playing.
    let discourseID: String

    @Environment(AudioPlayerService.self) private var player
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    private var transcripts = TranscriptService.shared
    private var stateService = TranscriptStateService.shared
    private var settings = UserSettings.shared
    private var aligner = SpeechAlignmentService.shared

    @State private var transcript: Transcript?
    @State private var loadError: Error?
    @State private var isLoading = false
    @State private var model: TranscriptSyncModel?
    /// Shipped timing for this transcript's paragraph split, if any.
    @State private var shippedAlignment: AlignmentCatalog.Entry?
    @State private var currentParagraph = 0
    /// Sentence within `currentParagraph` being spoken; only meaningful with
    /// aligned timing, where the paragraph boundaries are trustworthy.
    @State private var currentSentence: Int?
    @State private var isFollowing = true
    @State private var scrolledID: Int?
    @State private var interactionStartOffset: CGFloat?
    @State private var selectedParagraph: Int?
    @State private var isSearching = false
    @State private var searchText = ""
    @State private var searchCursor = 0
    @State private var toast: String?
    @FocusState private var searchFocused: Bool

    init(discourseID: String) {
        self.discourseID = discourseID
    }

    private var entry: (discourse: CatalogDiscourse, series: SeriesInfo)? {
        Catalog.discourseLookup[discourseID]
    }

    private var isPlayingThis: Bool { player.currentTrackId == discourseID }
    private var accent: Color { settings.effectiveAccentTheme.color }
    private var fontSize: CGFloat { CGFloat(settings.transcriptFontSize) }

    /// Pure read; `load()` reconciles the stored state against the paragraph
    /// count once, so body evaluation never mutates the service.
    private var discourseState: TranscriptDiscourseState? {
        guard transcript != nil else { return nil }
        return stateService.state(for: discourseID)
    }

    private var speechSyncSupported: Bool {
        guard let entry else { return false }
        return SpeechAlignmentService.isSupported(for: entry.series.language)
    }

    /// The shipped alignment when it describes the recording being played.
    private var shippedAlignmentInUse: AlignmentCatalog.Entry? {
        guard let shippedAlignment, let transcript, isPlayingThis, player.duration > 0,
              shippedAlignment.matches(paragraphCount: transcript.paragraphs.count, duration: player.duration)
        else { return nil }
        return shippedAlignment
    }

    /// Paragraph starts in force: shipped first, else the device's own result
    /// while the speech-sync toggle is on.
    private var alignedStarts: [TimeInterval?]? {
        if let shipped = shippedAlignmentInUse { return shipped.starts }
        if settings.transcriptSpeechSync, speechSyncSupported, let alignment = discourseState?.alignment { return alignment.starts }
        return nil
    }

    private var alignmentInUse: Bool { alignedStarts != nil }

    private var searchMatches: [Int] {
        guard isSearching, let transcript else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else { return [] }
        return transcript.paragraphs.filter { $0.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }.map(\.index)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                // Applied before the insets so the pill floats over the text,
                // not over the transport bar or the search field.
                .overlay(alignment: .bottom) {
                    if isPlayingThis, transcript != nil, !isFollowing, !isSearching {
                        nowPlayingPill
                            .padding(.bottom, 12)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        if isSearching { searchBar }
                        if aligner.discourseID == discourseID, aligner.status.isActive {
                            alignmentProgressRow
                        }
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if isPlayingThis, transcript != nil { transportBar }
                }
                .overlay(alignment: .top) {
                    if let toast {
                        Text(toast)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.top, isSearching ? 56 : 8)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: isFollowing)
                .animation(.easeInOut(duration: 0.2), value: toast)
        }
        .task(id: discourseID) { await load() }
        // Reading along means no touches for minutes at a time, so the idle
        // timer would dim the page mid-paragraph. Held only while this
        // discourse is actually playing; pausing or closing hands it back.
        .onAppear { updateIdleTimer() }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: player.isPlaying) { _, _ in updateIdleTimer() }
        .onChange(of: player.currentTrackId) { _, _ in updateIdleTimer() }
        .onChange(of: scenePhase) { _, _ in updateIdleTimer() }
        .onChange(of: player.currentTime) { _, time in updateCurrentParagraph(for: time) }
        .onChange(of: player.duration) { _, _ in rebuildModel() }
        .onChange(of: player.currentTrackId) { _, _ in
            rebuildModel()
            if isPlayingThis, isFollowing { withAnimation { scrolledID = currentParagraph } }
        }
        .onChange(of: discourseState?.anchors) { _, _ in rebuildModel() }
        .onChange(of: discourseState?.alignment) { _, _ in rebuildModel() }
        .onChange(of: settings.transcriptSpeechSync) { _, _ in rebuildModel() }
        .onChange(of: aligner.status) { _, status in
            guard aligner.discourseID == discourseID else { return }
            switch status {
            case .done(let matched, let total):
                showToast(matched > 0 ? "Synced \(matched) of \(total) paragraphs from speech" : "Speech sync found no matches")
            case .failed(let message):
                showToast("Speech sync failed: \(message)", seconds: 5)
            default:
                break
            }
        }
        .onChange(of: searchText) { _, _ in
            searchCursor = 0
            if let first = searchMatches.first {
                isFollowing = false
                withAnimation { scrolledID = first }
            }
        }
        .onChange(of: scrolledID) { _, id in
            // Only a manual scroll changes the saved read position; following
            // the audio is the default and needs no bookmark.
            guard let id, !isFollowing, let transcript else { return }
            stateService.setReadPosition(discourseID: discourseID, paragraph: id, paragraphCount: transcript.paragraphs.count)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let transcript {
            reader(transcript)
        } else if isLoading {
            ProgressView("Loading transcript…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            ContentUnavailableView {
                Label("Transcript unavailable", systemImage: "doc.plaintext")
            } description: {
                Text(loadError.localizedDescription)
            } actions: {
                if !(loadError is TranscriptFetcher.FetchError) {
                    Button("Try Again") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
                if let entry = TranscriptCatalog.entry(for: discourseID), let url = TranscriptCatalog.pageURL(for: entry) {
                    Link("Open on oshoworld.com", destination: url)
                }
            }
        } else {
            ContentUnavailableView(
                "No transcript yet",
                systemImage: "doc.plaintext",
                description: Text("oshoworld.com has not published a transcript for this discourse.")
            )
        }
    }

    // MARK: - Reader

    private func reader(_ transcript: Transcript) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(transcript.paragraphs) { paragraph in
                    paragraphRow(paragraph)
                        .id(paragraph.index)
                }
                // Room to bring the last paragraphs up to the highlight line.
                Color.clear.frame(height: 240)
            }
            .scrollTargetLayout()
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .scrollPosition(id: $scrolledID, anchor: UnitPoint(x: 0.5, y: 0.35))
        .onScrollPhaseChange { old, phase, context in
            // `.interacting` begins on touch-down, so a plain tap on a
            // paragraph would count as a scroll. Only a finger that actually
            // moved the content, or a fling, hands control to the reader.
            let offset = context.geometry.contentOffset.y
            switch phase {
            case .interacting:
                interactionStartOffset = offset
            case .decelerating:
                isFollowing = false
            default:
                if old == .interacting, let start = interactionStartOffset, abs(offset - start) > 24 {
                    isFollowing = false
                }
                interactionStartOffset = nil
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .contentMargins(.bottom, 8, for: .scrollContent)
        .onTapGesture { withAnimation { selectedParagraph = nil } }
    }

    private func paragraphRow(_ paragraph: Transcript.Paragraph) -> some View {
        let isCurrent = isPlayingThis && paragraph.index == currentParagraph
        let isSelected = selectedParagraph == paragraph.index
        let isPast = isPlayingThis && paragraph.index < currentParagraph
        return VStack(alignment: .leading, spacing: 10) {
            Text(attributedText(for: paragraph))
                .font(.system(size: fontSize, weight: isCurrent ? .semibold : .regular, design: paragraph.isEmphasis ? .serif : .default))
                .italic(paragraph.isEmphasis)
                .lineSpacing(fontSize * 0.28)
                .foregroundStyle(isCurrent || isSelected ? Color.primary : Color.primary.opacity(isPast ? 0.45 : 0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedParagraph = isSelected ? nil : paragraph.index
                    }
                }
            if isSelected {
                actionBar(for: paragraph)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isCurrent ? accent.opacity(0.10) : (isSelected ? Color.primary.opacity(0.05) : .clear))
        )
        .overlay(alignment: .leading) {
            if isCurrent {
                RoundedRectangle(cornerRadius: 2)
                    .fill(accent)
                    .frame(width: 3)
                    .padding(.vertical, 12)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isCurrent)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityHint(isSelected ? "" : "Tap for play, sync, copy and share")
    }

    private func attributedText(for paragraph: Transcript.Paragraph) -> AttributedString {
        var text = AttributedString(paragraph.text)
        if isPlayingThis, paragraph.index == currentParagraph, let currentSentence {
            let ranges = TranscriptSentences.ranges(in: paragraph.text)
            if ranges.count > 1 {
                for (i, range) in ranges.enumerated() where i != currentSentence {
                    if let lower = AttributedString.Index(range.lowerBound, within: text),
                       let upper = AttributedString.Index(range.upperBound, within: text) {
                        text[lower..<upper].foregroundColor = .primary.opacity(0.55)
                    }
                }
            }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard isSearching, query.count >= 2 else { return text }
        var searchRange = paragraph.text.startIndex..<paragraph.text.endIndex
        while let found = paragraph.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
            if let lower = AttributedString.Index(found.lowerBound, within: text),
               let upper = AttributedString.Index(found.upperBound, within: text) {
                text[lower..<upper].backgroundColor = .yellow.opacity(0.45)
            }
            searchRange = found.upperBound..<paragraph.text.endIndex
        }
        return text
    }

    // MARK: - Action bar

    private func actionBar(for paragraph: Transcript.Paragraph) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if isPlayingThis, let model {
                    actionChip("Play from here", systemImage: "play.fill") {
                        player.seekWithHistory(to: model.startTime(ofParagraph: paragraph.index))
                        if !player.isPlaying { player.togglePlayPause() }
                        resumeFollowing()
                        withAnimation { selectedParagraph = nil }
                    }
                    actionChip("Audio is here", systemImage: "scope") {
                        anchor(paragraph)
                    }
                }
                actionChip("Copy", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = paragraph.text
                    showToast("Copied")
                    withAnimation { selectedParagraph = nil }
                }
                ShareLink(item: shareText(for: paragraph)) {
                    chipLabel("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func actionChip(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { chipLabel(title, systemImage: systemImage) }
            .buttonStyle(.plain)
    }

    private func chipLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(accent.opacity(0.14), in: Capsule())
            .foregroundStyle(accent)
    }

    private func shareText(for paragraph: Transcript.Paragraph) -> String {
        guard let entry else { return paragraph.text }
        return "\(paragraph.text)\n\n— Osho, \(entry.series.name) #\(entry.discourse.number)"
    }

    /// Pin the paragraph to the current playback time and follow from there.
    private func anchor(_ paragraph: Transcript.Paragraph) {
        guard let transcript else { return }
        stateService.addAnchor(
            discourseID: discourseID,
            paragraph: paragraph.index,
            time: player.currentTime,
            paragraphCount: transcript.paragraphs.count
        )
        rebuildModel()
        withAnimation { selectedParagraph = nil }
        resumeFollowing()
        showToast("Synced to this paragraph")
    }

    // MARK: - Following

    private var nowPlayingPill: some View {
        Button(action: resumeFollowing) {
            Label("Now playing", systemImage: currentParagraph > (scrolledID ?? 0) ? "arrow.down" : "arrow.up")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(accent, in: Capsule())
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Scrolls back to the paragraph being spoken")
    }

    private func resumeFollowing() {
        isFollowing = true
        stateService.clearReadPosition(discourseID: discourseID)
        withAnimation(.easeInOut(duration: 0.4)) { scrolledID = currentParagraph }
    }

    private func updateCurrentParagraph(for time: TimeInterval) {
        guard isPlayingThis, let model else { return }
        let paragraph = model.paragraph(at: time)
        currentSentence = sentence(in: paragraph, at: time, model: model)
        guard paragraph != currentParagraph else { return }
        currentParagraph = paragraph
        if isFollowing {
            withAnimation(.easeInOut(duration: 0.45)) { scrolledID = paragraph }
        }
    }

    /// Sentence being spoken, from how far through the paragraph's span `time`
    /// is. Nil without aligned timing: an estimate can be minutes out, and a
    /// sentence marker would lend it a precision it does not have.
    private func sentence(in paragraph: Int, at time: TimeInterval, model: TranscriptSyncModel) -> Int? {
        guard alignmentInUse, let transcript, paragraph < transcript.paragraphs.count,
              paragraph + 1 < model.starts.count else { return nil }
        let span = model.starts[paragraph + 1] - model.starts[paragraph]
        guard span > 0 else { return nil }
        let fraction = (model.position(atTime: time) - model.starts[paragraph]) / span
        return TranscriptSentences.index(atFraction: fraction, in: transcript.paragraphs[paragraph].text)
    }

    private func rebuildModel() {
        guard let transcript, isPlayingThis else { model = nil; return }
        let base = TranscriptSyncModel(paragraphs: transcript.paragraphs, duration: player.duration)
        let anchors = discourseState?.anchors ?? []
        let knots: [TranscriptSyncModel.Knot]
        if let alignedStarts {
            knots = base.knots(alignedStarts: alignedStarts, anchors: anchors)
        } else {
            knots = anchors.compactMap { base.knot(for: $0) }
        }
        model = base.with(knots: knots)
        currentParagraph = model?.paragraph(at: player.currentTime) ?? 0
        currentSentence = model.flatMap { sentence(in: currentParagraph, at: player.currentTime, model: $0) }
    }

    // MARK: - Loading

    private func load() async {
        transcript = nil
        loadError = nil
        model = nil
        shippedAlignment = nil
        selectedParagraph = nil
        guard transcripts.availability(for: discourseID) != .unavailable else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await transcripts.transcript(for: discourseID)
            // First access parses the whole catalog; keep it off the main thread.
            let id = discourseID
            let shipped = await Task.detached(priority: .userInitiated) { AlignmentCatalog.entry(for: id) }.value
            transcript = loaded
            shippedAlignment = shipped?.paragraphCount == loaded.paragraphs.count ? shipped : nil
            rebuildModel()
            // Land where the reader left off, or on the audio.
            let state = stateService.state(for: discourseID, paragraphCount: loaded.paragraphs.count)
            if let read = state.readPosition, !read.isFollowing, read.paragraph < loaded.paragraphs.count {
                isFollowing = false
                scrolledID = read.paragraph
            } else {
                isFollowing = true
                scrolledID = isPlayingThis ? currentParagraph : 0
            }
            startAlignmentIfWanted(loaded)
            applyDebugArguments()
        } catch {
            loadError = error
        }
    }

    /// DEBUG launch arguments for layout checks in a simulator:
    /// `-debugTranscriptSearch <query>` opens search with the query typed,
    /// `-debugTranscriptSelect <index>` shows a paragraph's action bar.
    private func applyDebugArguments() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-debugTranscriptSearch"), args.indices.contains(i + 1) {
            isSearching = true
            searchText = args[i + 1]
        }
        if let i = args.firstIndex(of: "-debugTranscriptSelect"), args.indices.contains(i + 1),
           let index = Int(args[i + 1]) {
            isFollowing = false
            selectedParagraph = index
            scrolledID = index
        }
        #endif
    }

    private func startAlignmentIfWanted(_ transcript: Transcript) {
        guard settings.transcriptSpeechSync, speechSyncSupported, isPlayingThis, let entry,
              shippedAlignment == nil, discourseState?.alignment == nil,
              let url = player.downloadService?.localFileURL(for: discourseID) else { return }
        aligner.align(discourseID: discourseID, transcript: transcript, language: entry.series.language, audioURL: url)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .accessibilityLabel("Close")
        }
        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                Text(entry?.series.name ?? "Transcript")
                    .font(.headline)
                    .lineLimit(1)
                if let entry {
                    Text("Discourse \(entry.discourse.number)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                withAnimation { isSearching.toggle() }
                if isSearching { searchFocused = true } else { searchText = "" }
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .disabled(transcript == nil)
            .accessibilityLabel("Search transcript")

            Menu {
                Section("Text size") {
                    Button {
                        stepFontSize(-1)
                    } label: { Label("Smaller", systemImage: "textformat.size.smaller") }
                        .disabled(settings.transcriptFontSize <= UserSettings.transcriptFontSizes.first!)
                    Button {
                        stepFontSize(1)
                    } label: { Label("Larger", systemImage: "textformat.size.larger") }
                        .disabled(settings.transcriptFontSize >= UserSettings.transcriptFontSizes.last!)
                }
                if isPlayingThis {
                    Section("Timing") {
                        if let shipped = shippedAlignmentInUse {
                            Text("Synced from speech: \(shipped.matchedCount) of \(shipped.paragraphCount) paragraphs")
                        } else if speechSyncSupported {
                            Toggle(isOn: Binding(
                                get: { settings.transcriptSpeechSync },
                                set: { on in
                                    settings.transcriptSpeechSync = on
                                    if on, let transcript { startAlignmentIfWanted(transcript) } else { aligner.cancel() }
                                }
                            )) {
                                Label("Sync from speech on this device", systemImage: "waveform.badge.magnifyingglass")
                            }
                            if let alignment = discourseState?.alignment {
                                if settings.transcriptSpeechSync {
                                    Text("Synced from speech: \(alignment.matchedCount) of \(alignment.starts.count) paragraphs")
                                }
                                Button(role: .destructive) {
                                    stateService.clearAlignment(discourseID: discourseID)
                                    if settings.transcriptSpeechSync, let transcript { startAlignmentIfWanted(transcript) }
                                } label: { Label("Redo speech sync", systemImage: "arrow.clockwise") }
                            }
                        } else {
                            Text("Estimated from text length. Tap a paragraph and choose “Audio is here” to correct it.")
                        }
                        if let anchors = discourseState?.anchors, !anchors.isEmpty {
                            Button(role: .destructive) {
                                stateService.clearAnchors(discourseID: discourseID)
                                rebuildModel()
                            } label: { Label("Clear \(anchors.count) sync anchor\(anchors.count == 1 ? "" : "s")", systemImage: "scope") }
                        }
                    }
                }
                if let catalogEntry = TranscriptCatalog.entry(for: discourseID), let url = TranscriptCatalog.pageURL(for: catalogEntry) {
                    Section {
                        Link(destination: url) { Label("Open on oshoworld.com", systemImage: "safari") }
                    }
                }
            } label: {
                Image(systemName: "textformat.size")
            }
            .accessibilityLabel("Transcript options")
        }
    }

    private func stepFontSize(_ direction: Int) {
        let sizes = UserSettings.transcriptFontSizes
        let current = sizes.firstIndex(of: settings.transcriptFontSize)
            ?? sizes.indices.min(by: { abs(sizes[$0] - settings.transcriptFontSize) < abs(sizes[$1] - settings.transcriptFontSize) })
            ?? 2
        let next = min(max(current + direction, 0), sizes.count - 1)
        settings.transcriptFontSize = sizes[next]
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find in transcript", text: $searchText)
                    .layoutPriority(1)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .onSubmit { jumpToMatch(offset: 1) }
                if !searchText.isEmpty {
                    Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))

            if !searchMatches.isEmpty {
                Text("\(min(searchCursor + 1, searchMatches.count))/\(searchMatches.count)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button { jumpToMatch(offset: -1) } label: { Image(systemName: "chevron.up") }
                    .accessibilityLabel("Previous match")
                Button { jumpToMatch(offset: 1) } label: { Image(systemName: "chevron.down") }
                    .accessibilityLabel("Next match")
            } else if searchText.count >= 2 {
                Text("0/0").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }
            Button("Cancel") {
                withAnimation { isSearching = false }
                searchText = ""
                searchFocused = false
            }
            .font(.body)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        // The body text has its own size control; the bar itself has to stay
        // on one line, so it stops growing at the largest non-accessibility
        // size (the SE is 375 pt wide).
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private func jumpToMatch(offset: Int) {
        let matches = searchMatches
        guard !matches.isEmpty else { return }
        searchCursor = ((searchCursor + offset) % matches.count + matches.count) % matches.count
        isFollowing = false
        withAnimation { scrolledID = matches[searchCursor] }
    }

    // MARK: - Transport

    private var transportBar: some View {
        VStack(spacing: 8) {
            ProgressView(value: min(player.currentTime, max(player.duration, 1)), total: max(player.duration, 1))
                .tint(accent)
                .scaleEffect(x: 1, y: 0.6, anchor: .center)
            HStack {
                Text(formatTime(player.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .frame(minWidth: 64, alignment: .leading)
                Spacer()
                HStack(spacing: 28) {
                    Button { player.skipBackward() } label: {
                        Image(systemName: "gobackward.15").font(.title3)
                    }
                    .accessibilityLabel("Back 15 seconds")
                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                    Button { player.skipForward() } label: {
                        Image(systemName: "goforward.30").font(.title3)
                    }
                    .accessibilityLabel("Forward 30 seconds")
                }
                .foregroundStyle(.primary)
                Spacer()
                Text("-" + formatTime(max(0, player.duration - player.currentTime)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .frame(minWidth: 64, alignment: .trailing)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(.bar)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    // MARK: - Alignment progress

    private var alignmentProgressRow: some View {
        HStack(spacing: 12) {
            switch aligner.status {
            case .preparingAssets:
                ProgressView()
                Text("Preparing the \(entry?.series.language == .hindi ? "Hindi" : "English") speech model…")
            case .listening(let progress):
                ProgressView(value: progress)
                    .frame(maxWidth: 140)
                Text("Listening to the recording… \(Int(progress * 100))%")
            case .aligning:
                ProgressView()
                Text("Matching speech to the text…")
            default:
                EmptyView()
            }
            Spacer()
            Button("Stop") { aligner.cancel() }
                .font(.footnote)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    // MARK: - Helpers

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = isPlayingThis && player.isPlaying && scenePhase == .active
    }

    private func showToast(_ text: String, seconds: Double = 2) {
        toast = text
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if toast == text { toast = nil }
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let hrs = total / 3600, mins = (total % 3600) / 60, secs = total % 60
        return hrs > 0 ? String(format: "%d:%02d:%02d", hrs, mins, secs) : String(format: "%d:%02d", mins, secs)
    }
}
