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
    /// The transcript cut into display blocks, in reading order.
    @State private var blocks: [Block] = []
    @State private var currentParagraph = 0
    @State private var currentBlock: Block.ID?
    /// Sentence within the current block being spoken; only meaningful with
    /// aligned timing, where the paragraph boundaries are trustworthy.
    @State private var currentSentence: Int?
    @State private var isFollowing = true
    @State private var scrolledID: Block.ID?
    @State private var interactionStartOffset: CGFloat?
    @State private var selectedBlock: Block.ID?

    /// One piece of a paragraph as shown on screen. Long paragraphs are split
    /// at sentence boundaries (`TranscriptBlocks`); most are a single block.
    struct Block: Identifiable, Equatable {
        struct ID: Hashable { let paragraph: Int; let index: Int }
        let id: ID
        /// Position in reading order across the whole transcript.
        let ordinal: Int
        let text: String
        /// Character share of the paragraph this block covers.
        let start: Double
        let end: Double
        let isEmphasis: Bool
        let isLastInParagraph: Bool

        var paragraph: Int { id.paragraph }
        var isFirstInParagraph: Bool { id.index == 0 }
        var midpoint: Double { (start + end) / 2 }
    }
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

    private var searchMatches: [Block.ID] {
        guard isSearching else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else { return [] }
        return blocks.filter { $0.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }.map(\.id)
    }

    private func block(_ id: Block.ID?) -> Block? {
        guard let id else { return nil }
        return blocks.first { $0.id == id }
    }

    private func firstBlock(ofParagraph paragraph: Int) -> Block.ID? {
        blocks.first { $0.paragraph == paragraph }?.id
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
            if isPlayingThis, isFollowing { withAnimation { scrolledID = currentBlock } }
        }
        .onChange(of: discourseState?.anchors) { _, _ in rebuildModel() }
        .onChange(of: discourseState?.alignment) { _, _ in rebuildModel() }
        .onChange(of: settings.transcriptSpeechSync) { _, _ in rebuildModel() }
        .onChange(of: settings.transcriptSentenceLayout) { _, sentences in
            guard let transcript else { return }
            let paragraph = block(scrolledID)?.paragraph
            blocks = Self.blocks(for: transcript, sentences: sentences)
            selectedBlock = nil
            currentBlock = nil
            updateCurrentParagraph(for: player.currentTime)
            scrolledID = isFollowing ? currentBlock : paragraph.flatMap(firstBlock(ofParagraph:))
        }
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
            stateService.setReadPosition(discourseID: discourseID, paragraph: id.paragraph, paragraphCount: transcript.paragraphs.count)
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
                ForEach(blocks) { block in
                    blockRow(block)
                        .id(block.id)
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
        .onTapGesture { withAnimation { selectedBlock = nil } }
    }

    private func blockRow(_ block: Block) -> some View {
        let isCurrent = isPlayingThis && block.id == currentBlock
        let isSelected = selectedBlock == block.id
        let isPast = isPlayingThis && (self.block(currentBlock)?.ordinal ?? 0) > block.ordinal
        return VStack(alignment: .leading, spacing: 10) {
            Text(attributedText(for: block, isCurrent: isCurrent))
                .font(.system(size: fontSize, weight: isCurrent ? .semibold : .regular, design: block.isEmphasis ? .serif : .default))
                .italic(block.isEmphasis)
                .lineSpacing(fontSize * 0.28)
                .foregroundStyle(isCurrent || isSelected ? Color.primary : Color.primary.opacity(isPast ? 0.45 : 0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedBlock = isSelected ? nil : block.id
                    }
                }
            if isSelected {
                actionBar(for: block)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        // Cuts within one paragraph sit closer than real paragraph breaks.
        .padding(.top, block.isFirstInParagraph ? 10 : 3)
        .padding(.bottom, block.isLastInParagraph ? 10 : 3)
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

    private func attributedText(for block: Block, isCurrent: Bool) -> AttributedString {
        var text = AttributedString(block.text)
        if isCurrent, let currentSentence {
            let ranges = TranscriptSentences.ranges(in: block.text)
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
        var searchRange = block.text.startIndex..<block.text.endIndex
        while let found = block.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
            if let lower = AttributedString.Index(found.lowerBound, within: text),
               let upper = AttributedString.Index(found.upperBound, within: text) {
                text[lower..<upper].backgroundColor = .yellow.opacity(0.45)
            }
            searchRange = found.upperBound..<block.text.endIndex
        }
        return text
    }

    // MARK: - Action bar

    private func actionBar(for block: Block) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if isPlayingThis, let model {
                    actionChip("Play from here", systemImage: "play.fill") {
                        player.seekWithHistory(to: model.time(paragraph: block.paragraph, fraction: block.start))
                        if !player.isPlaying { player.togglePlayPause() }
                        resumeFollowing()
                        withAnimation { selectedBlock = nil }
                    }
                    actionChip("Audio is here", systemImage: "scope") {
                        anchor(block)
                    }
                }
                actionChip("Copy", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = block.text
                    showToast("Copied")
                    withAnimation { selectedBlock = nil }
                }
                ShareLink(item: shareText(for: block)) {
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

    private func shareText(for block: Block) -> String {
        guard let entry else { return block.text }
        return "\(block.text)\n\n— Osho, \(entry.series.name) #\(entry.discourse.number)"
    }

    /// Pin the block to the current playback time and follow from there. A
    /// whole-paragraph block keeps the plain anchor older app versions read.
    private func anchor(_ block: Block) {
        guard let transcript else { return }
        let isWholeParagraph = block.start == 0 && block.end == 1
        stateService.addAnchor(
            discourseID: discourseID,
            paragraph: block.paragraph,
            time: player.currentTime,
            fraction: isWholeParagraph ? nil : block.midpoint,
            paragraphCount: transcript.paragraphs.count
        )
        rebuildModel()
        withAnimation { selectedBlock = nil }
        resumeFollowing()
        showToast(settings.transcriptSentenceLayout ? "Synced to this sentence" : "Synced to this paragraph")
    }

    // MARK: - Following

    private var nowPlayingPill: some View {
        Button(action: resumeFollowing) {
            Label("Now playing", systemImage: (block(currentBlock)?.ordinal ?? 0) > (block(scrolledID)?.ordinal ?? 0) ? "arrow.down" : "arrow.up")
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
        withAnimation(.easeInOut(duration: 0.4)) { scrolledID = currentBlock }
    }

    private func updateCurrentParagraph(for time: TimeInterval) {
        guard isPlayingThis, let model else { return }
        let paragraph = model.paragraph(at: time)
        let fraction = model.fraction(atTime: time, inParagraph: paragraph)
        currentParagraph = paragraph
        let block = blocks.last { $0.paragraph == paragraph && $0.start <= fraction } ?? blocks.first { $0.paragraph == paragraph }
        currentSentence = block.flatMap { sentence(in: $0, atFraction: fraction) }
        guard block?.id != currentBlock else { return }
        currentBlock = block?.id
        if isFollowing {
            withAnimation(.easeInOut(duration: 0.45)) { scrolledID = currentBlock }
        }
    }

    /// Sentence being spoken within a block, from how far through the
    /// paragraph the audio is. Nil without aligned timing: an estimate can be
    /// minutes out, and a sentence marker would lend it a precision it does
    /// not have.
    private func sentence(in block: Block, atFraction fraction: Double) -> Int? {
        guard alignmentInUse, block.end > block.start else { return nil }
        return TranscriptSentences.index(atFraction: (fraction - block.start) / (block.end - block.start), in: block.text)
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
        updateCurrentParagraph(for: player.currentTime)
    }

    // MARK: - Loading

    private func load() async {
        transcript = nil
        loadError = nil
        model = nil
        shippedAlignment = nil
        selectedBlock = nil
        blocks = []
        guard transcripts.availability(for: discourseID) != .unavailable else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await transcripts.transcript(for: discourseID)
            // First access parses the whole catalog; keep it off the main thread.
            let id = discourseID
            let shipped = await Task.detached(priority: .userInitiated) { AlignmentCatalog.entry(for: id) }.value
            transcript = loaded
            blocks = Self.blocks(for: loaded, sentences: settings.transcriptSentenceLayout)
            shippedAlignment = shipped?.paragraphCount == loaded.paragraphs.count ? shipped : nil
            rebuildModel()
            // Land where the reader left off, or on the audio.
            let state = stateService.state(for: discourseID, paragraphCount: loaded.paragraphs.count)
            if let read = state.readPosition, !read.isFollowing, read.paragraph < loaded.paragraphs.count {
                isFollowing = false
                scrolledID = firstBlock(ofParagraph: read.paragraph)
            } else {
                isFollowing = true
                scrolledID = isPlayingThis ? currentBlock : blocks.first?.id
            }
            startAlignmentIfWanted(loaded)
            applyDebugArguments()
        } catch {
            loadError = error
        }
    }

    /// DEBUG launch arguments for layout checks in a simulator:
    /// `-debugTranscriptSearch <query>` opens search with the query typed,
    /// `-debugTranscriptSelect <index>` shows a paragraph's action bar,
    /// `-debugTranscriptFollow` ignores any saved read position.
    private func applyDebugArguments() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-debugTranscriptSearch"), args.indices.contains(i + 1) {
            isSearching = true
            searchText = args[i + 1]
        }
        if args.contains("-debugTranscriptFollow") { resumeFollowing() }
        if let i = args.firstIndex(of: "-debugTranscriptSelect"), args.indices.contains(i + 1),
           let index = Int(args[i + 1]) {
            isFollowing = false
            selectedBlock = firstBlock(ofParagraph: index)
            scrolledID = selectedBlock
        }
        #endif
    }

    static func blocks(for transcript: Transcript, sentences: Bool) -> [Block] {
        var result: [Block] = []
        for paragraph in transcript.paragraphs {
            let ranges = sentences ? TranscriptBlocks.sentenceRanges(in: paragraph.text) : TranscriptBlocks.ranges(in: paragraph.text)
            let shares = TranscriptBlocks.fractions(of: ranges, in: paragraph.text)
            for (i, range) in ranges.enumerated() {
                result.append(Block(
                    id: Block.ID(paragraph: paragraph.index, index: i),
                    ordinal: result.count,
                    text: String(paragraph.text[range]),
                    start: shares[i].start,
                    end: shares[i].end,
                    isEmphasis: paragraph.isEmphasis,
                    isLastInParagraph: i == ranges.count - 1
                ))
            }
        }
        return result
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
                Section("Layout") {
                    Toggle(isOn: Binding(
                        get: { settings.transcriptSentenceLayout },
                        set: { settings.transcriptSentenceLayout = $0 }
                    )) {
                        Label("One sentence per line", systemImage: "text.justify.leading")
                    }
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
