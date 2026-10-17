import SwiftUI
#if TRANSLATED_NARRATION
import AVFoundation
#endif

struct SeriesDetailView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(DownloadService.self) private var downloads
    @Environment(PlaybackStateService.self) private var playbackState
    @Environment(\.horizontalSizeClass) private var sizeClass
    let seriesInfo: SeriesInfo
    @State private var showDownloadAllConfirm = false
    /// Listening through translation: rows open or play the narration instead of the recording.
    @State private var listensTranslated = false
    @State private var translationDiscourse: CatalogDiscourse?
    #if TRANSLATED_NARRATION
    @State private var selectedTargetLanguage = ""
    @State private var availableTargetLanguages: [String]?
    @State private var targetsWithoutVoices = Set<String>()
    @State private var checkingLanguages = true
    @State private var languageCheckFailed = false
    @State private var languageRefreshID = 0
    #endif

    private var isRegular: Bool { AppLayout.isRegular(sizeClass) }
    /// Header and list share one column so their edges line up on iPad.
    private static let regularColumnWidth: CGFloat = 820

    private var discourses: [CatalogDiscourse] {
        Catalog.discourses(for: seriesInfo)
    }

    /// Only this series' own downloads justify the notice here.
    private var showsWaitingNotice: Bool {
        downloads.waitingReason != nil && discourses.contains { downloads.isDownloading($0.id) && !downloads.isQueued($0.id) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if isRegular {
                    regularHeader
                } else {
                    headerSection
                    listeningPicker
                        .padding(.horizontal)
                        .padding(.bottom, 16)
                    if !listensTranslated { downloadAllButton }
                }
                if showsWaitingNotice {
                    DownloadWaitingNotice()
                        .padding(16)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
                discourseList
            }
            .padding(.bottom, 16)
            .frame(maxWidth: isRegular ? Self.regularColumnWidth : .infinity)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemBackground))
        .reservesMiniPlayerSpace()
        .navigationTitle(seriesInfo.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        for discourse in discourses {
                            playbackState.markCompleted(discourseId: discourse.id)
                        }
                    } label: {
                        Label("Mark All Complete", systemImage: "checkmark.circle.fill")
                    }
                    Button(role: .destructive) {
                        for discourse in discourses {
                            playbackState.unmarkCompleted(discourseId: discourse.id)
                        }
                    } label: {
                        Label("Mark All Incomplete", systemImage: "xmark.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More options")
            }
        }
        #if TRANSLATED_NARRATION
        .onAppear { refreshListeningPreferences() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            refreshListeningPreferences()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)) { _ in
            languageRefreshID += 1
        }
        .task { await NarrationService.shared.loadIfNeeded() }
        .task(id: languageRefreshID) { await loadListeningLanguages() }
        .sheet(item: $translationDiscourse, onDismiss: refreshListeningPreferences) { discourse in
            if #available(macCatalyst 26.0, *) {
                let target = listeningTargetLanguage
                TranslatedNarrationView(
                    discourseID: discourse.id,
                    selectedDocumentID: TranslatedListening.savedNarration(
                        for: discourse.id, target: target, in: NarrationService.shared.documents
                    )?.id,
                    preferredTargetLanguage: target
                )
                .environment(player)
                .environment(downloads)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
        #endif
    }

    @ViewBuilder
    private var listeningPicker: some View {
        #if TRANSLATED_NARRATION
        if TranslatedListening.canTranslate(seriesInfo) {
            Menu {
                Button { selectListeningLanguage(nil) } label: {
                    Label("Osho's original recording", systemImage: listensTranslated ? "waveform" : "checkmark")
                }
                .accessibilityLabel("Osho's original recording")
                .accessibilityIdentifier("series.listeningOriginal")
                Divider()
                if checkingLanguages {
                    Text("Checking translation languages…")
                }
                if let availableTargetLanguages {
                    ForEach(availableTargetLanguages, id: \.self) { language in
                        Button { selectListeningLanguage(language) } label: {
                            let name = NarrationLanguageSupport.displayName(for: language)
                            let title = targetsWithoutVoices.contains(language) ? "\(name) (voice needed)" : name
                            if listensTranslated && language == listeningTargetLanguage {
                                Label(title, systemImage: "checkmark")
                            } else {
                                Text(title)
                            }
                        }
                        .accessibilityLabel(NarrationLanguageSupport.displayName(for: language))
                        .accessibilityHint(targetsWithoutVoices.contains(language) ? "A system voice is needed to translate this discourse" : "")
                        .accessibilityIdentifier("series.listeningTarget.\(language)")
                    }
                    if availableTargetLanguages.isEmpty && !checkingLanguages {
                        Text("No translation languages available")
                    }
                }
                if languageCheckFailed {
                    Text("Couldn't check translation languages")
                }
                if !checkingLanguages {
                    Divider()
                    Button(languageCheckFailed ? "Try Again" : "Refresh Languages", systemImage: "arrow.clockwise") {
                        languageRefreshID += 1
                    }
                    .accessibilityIdentifier("series.refreshListeningLanguages")
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                    Text(listensTranslated
                         ? "Listen in \(NarrationLanguageSupport.displayName(for: listeningTargetLanguage))"
                         : "Osho's original recording")
                    if checkingLanguages {
                        ProgressView().controlSize(.small)
                    } else if languageCheckFailed {
                        Image(systemName: "exclamationmark.circle")
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .font(.subheadline)
                .frame(minHeight: 44)
            }
            .accessibilityIdentifier("series.listeningLanguage")
            .accessibilityValue(listeningAccessibilityValue)
        }
        #endif
    }

    private var listeningTargetLanguage: String {
        #if TRANSLATED_NARRATION
        selectedTargetLanguage.isEmpty ? TranslatedListening.targetLanguage(for: seriesInfo) : selectedTargetLanguage
        #else
        ""
        #endif
    }

    #if TRANSLATED_NARRATION
    private var listeningAccessibilityValue: String {
        let choice = listensTranslated ? NarrationLanguageSupport.displayName(for: listeningTargetLanguage) : "Original recording"
        if checkingLanguages { return "\(choice), checking translation languages" }
        if languageCheckFailed { return "\(choice), couldn't check translation languages" }
        return choice
    }

    private func refreshListeningPreferences() {
        listensTranslated = TranslatedListening.prefersTranslation(seriesInfo, filter: UserSettings.shared.languageFilter)
        selectedTargetLanguage = availableTargetLanguages.flatMap {
            TranslatedListening.resolvedTargetLanguage(for: seriesInfo, availableLanguages: $0)
        } ?? TranslatedListening.targetLanguage(for: seriesInfo)
    }

    private func selectListeningLanguage(_ language: String?) {
        if let language {
            TranslatedListening.setTargetLanguage(language, for: seriesInfo)
            selectedTargetLanguage = language
            listensTranslated = true
        } else {
            TranslatedListening.setPrefersTranslation(false, for: seriesInfo)
            listensTranslated = false
        }
    }

    private func loadListeningLanguages() async {
        guard TranslatedListening.canTranslate(seriesInfo) else { return }
        guard #available(macCatalyst 26.0, *) else { return }
        checkingLanguages = true
        languageCheckFailed = false
        do {
            let languages = try await NarrationLanguageSupport.availableLanguages(
                sourceLanguage: NarrationLanguageSupport.sourceLanguage(for: seriesInfo.language),
                voices: NativeNarrationSpeechRenderer.availableVoices()
            )
            guard !Task.isCancelled else { return }
            availableTargetLanguages = languages.map(\.id)
            targetsWithoutVoices = Set(languages.filter { $0.voices.isEmpty }.map(\.id))
            refreshListeningPreferences()
        } catch {
            guard !Task.isCancelled else { return }
            languageCheckFailed = true
        }
        checkingLanguages = false
    }
    #endif

    private var headerSection: some View {
        VStack(spacing: 16) {
            SeriesThumbnailView(name: seriesInfo.name, size: 120, seriesID: seriesInfo.id)
                .shadow(color: .primary.opacity(0.1), radius: 20)

            VStack(spacing: 6) {
                Text(seriesInfo.name)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                HStack(spacing: 8) {
                    Text("\(seriesInfo.count) discourses")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text("·")
                        .foregroundStyle(.secondary)

                    Text(seriesInfo.language == .hindi ? "Hindi" : "English")
                        .font(.subheadline)
                        .foregroundStyle(Color.accent)
                }

                let completedCount = playbackState.completedCount(for: seriesInfo.id)
                if completedCount > 0 {
                    Text("\(completedCount)/\(seriesInfo.count) completed")
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                let transcriptCount = TranscriptCatalog.transcriptCount(forSeriesID: seriesInfo.id)
                if transcriptCount > 0 {
                    Label(
                        transcriptCount == seriesInfo.count
                            ? "Transcripts for every discourse"
                            : "Transcripts for \(transcriptCount) of \(seriesInfo.count)",
                        systemImage: "doc.plaintext"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if let meta = SeriesMetadata.description(for: seriesInfo.name) {
                    VStack(spacing: 8) {
                        Text(meta.sourceText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(4)

                        if let year = meta.year, let location = meta.location {
                            Text("\(location), \(year)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }

                        if !meta.themes.isEmpty {
                            FlowLayout(spacing: 4) {
                                ForEach(meta.themes.prefix(5), id: \.self) { theme in
                                    Text(theme)
                                        .font(.system(size: 10))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.accent.opacity(0.1))
                                        .foregroundStyle(Color.accent)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }
                    .padding(.top, 8)
                    .padding(.horizontal, 16)
                }
            }
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }

    /// Podcasts-style header for wide windows: cover beside the details, so
    /// the first discourses are visible without scrolling.
    private var regularHeader: some View {
        HStack(alignment: .top, spacing: 24) {
            SeriesThumbnailView(name: seriesInfo.name, size: 176, seriesID: seriesInfo.id)
                .shadow(color: .primary.opacity(0.08), radius: 16)

            VStack(alignment: .leading, spacing: 8) {
                Text(seriesInfo.name)
                    .font(.largeTitle.bold())
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Text("\(seriesInfo.count) discourses")
                        .foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.secondary)
                    Text(seriesInfo.language == .hindi ? "Hindi" : "English")
                        .foregroundStyle(Color.accent)
                    let completedCount = playbackState.completedCount(for: seriesInfo.id)
                    if completedCount > 0 {
                        Text("·").foregroundStyle(.secondary)
                        Text("\(completedCount)/\(seriesInfo.count) completed")
                            .foregroundStyle(.green)
                    }
                }
                .font(.subheadline)

                let transcriptCount = TranscriptCatalog.transcriptCount(forSeriesID: seriesInfo.id)
                if transcriptCount > 0 {
                    Label(
                        transcriptCount == seriesInfo.count
                            ? "Transcripts for every discourse"
                            : "Transcripts for \(transcriptCount) of \(seriesInfo.count)",
                        systemImage: "doc.plaintext"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                if let meta = SeriesMetadata.description(for: seriesInfo.name) {
                    Text(meta.sourceText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(5)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                    if let year = meta.year, let location = meta.location {
                        Text("\(location), \(year)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                listeningPicker
                    .frame(maxWidth: 360)
                    .padding(.top, 8)
                if !listensTranslated {
                    downloadAllControl
                        .frame(maxWidth: 360)
                        .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal)
        .padding(.top, 24)
        .padding(.bottom, 24)
    }

    private var remainingCount: Int {
        discourses.filter { !downloads.isDownloaded($0.id) }.count
    }

    private var estimatedTotalSize: String {
        let perFile = seriesInfo.language == .hindi ? 20 : 30
        let totalMB = remainingCount * perFile
        if totalMB >= 1000 {
            return String(format: "~%.1f GB", Double(totalMB) / 1000.0)
        }
        return "~\(totalMB) MB"
    }

    private var downloadAllButton: some View {
        downloadAllControl
            .padding(.horizontal)
            .padding(.bottom, 20)
    }

    private var downloadAllControl: some View {
        Button {
            showDownloadAllConfirm = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                Text("Download All")
                    .fontWeight(.semibold)
                if remainingCount > 0 {
                    Text("(\(remainingCount) · \(estimatedTotalSize))")
                        .fontWeight(.regular)
                        .opacity(0.8)
                }
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.accent.opacity(0.15))
            .foregroundStyle(Color.accent)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .hoverEffect(.highlight)
        .confirmationDialog(
            "Download \(remainingCount) discourses?",
            isPresented: $showDownloadAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Download \(remainingCount) (\(estimatedTotalSize))") {
                Task {
                    for discourse in discourses where !downloads.isDownloaded(discourse.id) {
                        _ = try? await downloads.download(discourse)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will download \(remainingCount) discourses using approximately \(estimatedTotalSize) of storage.")
        }
    }

    private var discourseList: some View {
        LazyVStack(spacing: 0) {
            ForEach(discourses) { discourse in
                DiscourseRowView(
                    discourse: discourse, seriesInfo: seriesInfo, listensTranslated: listensTranslated,
                    targetLanguage: listeningTargetLanguage,
                    openTranslation: { translationDiscourse = $0 }
                )

                if discourse.id != discourses.last?.id {
                    Divider()
                        .padding(.leading, 52)
                }
            }
        }
    }
}

// MARK: - Discourse Row

private struct DiscourseRowView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(DownloadService.self) private var downloads
    @Environment(PlaybackStateService.self) private var playbackState
    @Environment(AppNavigation.self) private var navigation: AppNavigation?
    let discourse: CatalogDiscourse
    let seriesInfo: SeriesInfo
    var listensTranslated = false
    var targetLanguage = ""
    var openTranslation: (CatalogDiscourse) -> Void = { _ in }
    @State private var showDownloadHint = false
    @State private var showTranscript = false

    private var hasTranscript: Bool {
        TranscriptCatalog.hasTranscript(discourse.id)
    }

    private var isCurrentlyPlaying: Bool {
        player.currentTrackId == discourse.id && player.isPlaying
    }

    private var isDownloaded: Bool {
        downloads.isDownloaded(discourse.id)
    }

    private var isCompleted: Bool {
        playbackState.isCompleted(discourse.id)
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Text("\(discourse.number)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if isCompleted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                        .offset(x: 10, y: -8)
                        .accessibilityLabel("Completed")
                }
            }
            .frame(width: 28, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                // No per-discourse titles exist in the catalog, and the series
                // name is already in the hero header, so a plain "Discourse N"
                // reads clearly without repeating (and truncating) the series name.
                HStack(spacing: 6) {
                    Text("Discourse \(discourse.number)")
                        .font(.body)
                        .lineLimit(1)
                        .foregroundStyle(isCurrentlyPlaying ? .blue : .primary)
                    if hasTranscript {
                        Image(systemName: "doc.plaintext")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("Transcript available")
                    }
                }

                if translatedMode {
                    if let translationStatus {
                        Text(translationStatus)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else if let failureMessage {
                    Text(failureMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if downloads.isDownloading(discourse.id), !downloads.isQueued(discourse.id),
                          let waiting = downloads.waitingReason {
                    Text(waiting.rowLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if showDownloadHint {
                    Text("Downloading...")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }

            Spacer()

            if translatedMode { translationButton } else { actionButton }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .opacity(listensTranslated && !hasTranscript ? 0.5 : 1)
        .onTapGesture {
            if translatedMode { openTranslation(discourse) } else if !listensTranslated { playDiscourse() }
        }
        // The row plays on tap of a plain HStack, which VoiceOver can't
        // discover on its own — expose it as a button with the same action.
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Discourse \(discourse.number)\(isCompleted ? ", completed" : "")\(hasTranscript ? ", transcript available" : "")")
        .accessibilityIdentifier("series.discourse.\(discourse.id)")
        .accessibilityValue(translatedMode ? "\(targetName) translation" : "Original recording")
        .accessibilityHint(rowHint)
        .accessibilityAction {
            if translatedMode { openTranslation(discourse) } else if !listensTranslated { playDiscourse() }
        }
        .hoverEffect(.highlight)
        .contextMenu {
            if isDownloaded {
                Button {
                    if player.currentTrackId == discourse.id { player.togglePlayPause() } else { playDiscourse() }
                } label: {
                    Label(isCurrentlyPlaying ? "Pause" : "Play", systemImage: isCurrentlyPlaying ? "pause" : "play")
                }
            } else if !downloads.isDownloading(discourse.id) {
                Button {
                    downloads.startDownload(discourse)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            }
            if player.currentTrackId == discourse.id, let navigation {
                Button {
                    navigation.addBookmark()
                } label: {
                    Label("Add Bookmark…", systemImage: "bookmark")
                }
            }
            if hasTranscript {
                Button {
                    showTranscript = true
                } label: {
                    Label("Read Transcript", systemImage: "doc.plaintext")
                }
            }
            #if TRANSLATED_NARRATION
            if !translatedMode, hasTranscript, TranslatedListening.isSupported {
                Button {
                    openTranslation(discourse)
                } label: {
                    Label("Listen in \(targetName)…", systemImage: "globe")
                }
            }
            #endif
            if playbackState.isCompleted(discourse.id) {
                Button {
                    playbackState.unmarkCompleted(discourseId: discourse.id)
                } label: {
                    Label("Mark as Incomplete", systemImage: "xmark.circle")
                }
            } else {
                Button {
                    playbackState.markCompleted(discourseId: discourse.id)
                } label: {
                    Label("Mark as Complete", systemImage: "checkmark.circle")
                }
            }
            if isDownloaded {
                Divider()
                Button(role: .destructive) {
                    try? downloads.deleteDownload(discourseID: discourse.id)
                } label: {
                    Label("Remove Download", systemImage: "trash")
                }
            }
        }
        .sheet(isPresented: $showTranscript) {
            // Re-injected like every other sheet in the app (see ContentView).
            TranscriptView(discourseID: discourse.id)
                .environment(player)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private var estimatedSize: String {
        seriesInfo.language == .hindi ? "~20 MB" : "~30 MB"
    }

    /// Translated listening needs the transcript; rows without one stay inert in that mode.
    private var translatedMode: Bool { listensTranslated && hasTranscript }

    private var rowHint: String {
        if translatedMode { return "Opens the \(targetName) translation" }
        if listensTranslated { return "No transcript to translate yet" }
        return isDownloaded ? "Plays this discourse" : "Downloads this discourse"
    }

    #if TRANSLATED_NARRATION
    private var targetName: String { NarrationLanguageSupport.displayName(for: targetLanguage) }
    private var savedTranslation: NarrationDocument? {
        TranslatedListening.savedNarration(
            for: discourse.id, target: targetLanguage,
            in: NarrationService.shared.documents
        )
    }
    private var isTranslating: Bool {
        let narrations = NarrationService.shared
        guard narrations.preparingDiscourseID == discourse.id,
              let preparing = narrations.documents.first(where: { $0.id == narrations.preparingDocumentID }) else { return false }
        return NarrationLanguageSupport.languageAndScript(for: preparing.selection.targetLanguage)
            == NarrationLanguageSupport.languageAndScript(for: targetLanguage)
    }

    private var translationStatus: String? {
        let narrations = NarrationService.shared
        if isTranslating, narrations.totalPassages > 0 {
            return "Translating · " + NarrationTimeFormatting.passages(narrations.completedPassages, of: narrations.totalPassages)
        }
        guard let saved = savedTranslation else { return nil }
        if saved.isComplete { return "\(targetName) ready" }
        return NarrationTimeFormatting.passages(saved.segments.count, of: saved.expectedSegmentCount) + " in \(targetName)"
    }

    @ViewBuilder
    private var translationButton: some View {
        let narrations = NarrationService.shared
        if let saved = savedTranslation, saved.isComplete ? narrations.audioURL(for: saved) != nil : !saved.segments.isEmpty {
            // Part of a translation is enough to start listening; the row's other tap continues translating.
            let current = player.currentNarration?.id == saved.id
            Button {
                if current, player.narrationPlaybackFailure == nil {
                    player.togglePlayPause()
                } else {
                    let loadedTrack = player.currentTrackId
                    Task {
                        let start = await TranslatedListening.translatedStart(for: saved, player: player)
                        guard player.currentTrackId == loadedTrack else { return }
                        NarrationPreviewPlayback.shared.play(documentID: saved.id, player: player, resumeAt: start)
                    }
                }
            } label: {
                Image(systemName: current && player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accent)
            }
            .accessibilityLabel(current && player.isPlaying ? "Pause \(targetName) translation" : "Play \(targetName) translation")
        } else if isTranslating {
            Button { openTranslation(discourse) } label: {
                CircularProgressView(progress: narrations.progress).frame(width: 28, height: 28)
            }
            .accessibilityLabel("Translating")
            .accessibilityValue("\(Int(narrations.progress * 100)) percent")
        } else if let saved = savedTranslation {
            Button { openTranslation(discourse) } label: {
                CircularProgressView(progress: Double(saved.segments.count) / Double(max(1, saved.expectedSegmentCount)))
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel("Continue \(targetName) translation")
        } else {
            Button { openTranslation(discourse) } label: {
                Image(systemName: "globe")
                    .font(.title3)
                    .foregroundStyle(Color.accent)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Translate into \(targetName)")
        }
    }
    #else
    private var targetName: String { "" }
    private var translationStatus: String? { nil }
    private var translationButton: some View { EmptyView() }
    #endif

    private var isFailed: Bool {
        guard let dl = downloads.activeDownloads[discourse.id] else { return false }
        if case .failed = dl.status { return true }
        return false
    }

    /// The plain-language reason a download failed, shown under the title so the
    /// listener knows why nothing happened instead of a silent no-op.
    private var failureMessage: String? {
        guard let dl = downloads.activeDownloads[discourse.id],
              case .failed(let message) = dl.status else { return nil }
        return message
    }

    @ViewBuilder
    private var actionButton: some View {
        if downloads.isDownloading(discourse.id) {
            Button {
                downloads.cancelDownload(discourseID: discourse.id)
            } label: {
                CircularProgressView(
                    progress: downloads.progress(for: discourse.id),
                    isQueued: downloads.isQueued(discourse.id)
                )
                .frame(width: 28, height: 28)
            }
            .accessibilityLabel("Cancel download")
            .accessibilityValue(downloads.isQueued(discourse.id) ? "Queued" : "\(Int(downloads.progress(for: discourse.id) * 100)) percent")
        } else if isFailed {
            Button {
                downloads.startDownload(discourse)
            } label: {
                Image(systemName: "exclamationmark.arrow.circlepath")
                    .font(.title3)
                    .foregroundStyle(.red)
            }
            .accessibilityLabel("Retry download")
        } else if isDownloaded {
            Button {
                playDiscourse()
            } label: {
                Image(systemName: isCurrentlyPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accent)
            }
            .accessibilityLabel(isCurrentlyPlaying ? "Pause" : "Play")
        } else {
            Button {
                downloads.startDownload(discourse)
            } label: {
                Text("GET \(estimatedSize)")
                    .font(.caption.bold())
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.accent.opacity(0.15))
                    .foregroundStyle(Color.accent)
                    .clipShape(Capsule())
            }
        }
    }

    private func playDiscourse() {
        guard downloads.localFileURL(for: discourse.id) != nil else {
            // Not downloaded yet — start download and show hint
            downloads.startDownload(discourse)
            withAnimation {
                showDownloadHint = true
            }
            Task {
                try? await Task.sleep(for: .seconds(2))
                withAnimation {
                    showDownloadHint = false
                }
            }
            return
        }

        let allDiscourses = Catalog.discourses(for: seriesInfo)
        let queueItems = allDiscourses
            .filter { downloads.isDownloaded($0.id) }
            .compactMap { d -> AudioPlayerService.QueueItem? in
                guard let fileURL = downloads.localFileURL(for: d.id) else { return nil }
                return AudioPlayerService.QueueItem(
                    id: d.id,
                    url: fileURL,
                    title: d.displayTitle,
                    series: seriesInfo.name
                )
            }

        let startIndex = queueItems.firstIndex { $0.id == discourse.id } ?? 0
        player.playQueue(items: queueItems, startIndex: startIndex)
    }
}

// MARK: - Circular Progress

private struct CircularProgressView: View {
    let progress: Double
    /// When waiting behind another transfer, show a gentle indeterminate spinner
    /// instead of a progress ring pinned at 0% (which reads as "stuck").
    var isQueued: Bool = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.15), lineWidth: 2.5)

            if isQueued {
                ProgressView()
                    .controlSize(.small)
            } else {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                Image(systemName: "stop.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Color.accent)
            }
        }
    }
}
