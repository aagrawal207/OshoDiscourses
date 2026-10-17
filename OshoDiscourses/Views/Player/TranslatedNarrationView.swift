#if TRANSLATED_NARRATION
import AVFoundation
import SwiftUI
import Translation
import os

@available(macCatalyst 26.0, *)
struct TranslatedNarrationView: View {
    let discourseID: String
    @Environment(AudioPlayerService.self) private var player
    @Environment(DownloadService.self) private var downloads
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.narrationPreparationHostID) private var hostID
    private let narrations = NarrationService.shared
    private let transcripts = TranscriptService.shared
    private let preparation = NarrationPreparationController.shared

    @State private var cacheLoaded = false
    @State private var cacheReloadGeneration = 0
    @State private var cacheError: String?
    @State private var playableIDs = Set<String>()
    @State private var originalAudioURL: URL?
    @State private var readingDocument: NarrationDocument?
    @State private var featuredVariantID: String?
    @State private var languages: [NarrationLanguageOption] = []
    @State private var selectedLanguageID = ""
    @State private var selectedVoiceID = ""
    @State private var pace = NarrationPace.preferred
    @State private var loadingLanguages = false
    @State private var languagesChecked = false
    @State private var availabilityError: String?
    @State private var availabilityTask: Task<Void, Never>?
    @State private var availabilityRequestID: UUID?
    @State private var errorMessage: String?
    @State private var deletingIDs = Set<String>()
    @State private var isVisible = false
    @State private var presentationOwner = UUID()
    @State private var showSpeed = false
    @State private var showSleepTimer = false
    @State private var pendingDeletion: NarrationDocument?
    @State private var showOptions = false

    private static let log = Logger(subsystem: "com.agraabhi.oshodiscourses", category: "NarrationTranslation")

    /// Language chosen before the sheet opened, such as a series listened to in Hindi.
    private let preferredTargetLanguage: String?

    init(discourseID: String, selectedDocumentID: String? = nil, preferredTargetLanguage: String? = nil) {
        self.discourseID = discourseID
        self.preferredTargetLanguage = preferredTargetLanguage
        _featuredVariantID = State(initialValue: selectedDocumentID)
    }

    private var entry: (discourse: CatalogDiscourse, series: SeriesInfo)? { Catalog.discourseLookup[discourseID] }
    private var sourceLanguage: String? { entry.map { NarrationLanguageSupport.sourceLanguage(for: $0.series.language) } }
    private var variants: [NarrationDocument] {
        narrations.documents.filter { $0.discourseID == discourseID }.sorted { $0.updatedAt > $1.updatedAt }
    }
    private var featuredVariant: NarrationDocument? { variants.first { $0.id == featuredVariantID } }
    private var selectedLanguage: NarrationLanguageOption? { languages.first { $0.id == selectedLanguageID } }
    private var selection: NarrationSelection? {
        guard let sourceLanguage, let target = selectedLanguage,
              let voice = target.voices.first(where: { $0.id == selectedVoiceID }) else { return nil }
        return NarrationSelection(sourceLanguage: sourceLanguage, targetLanguage: target.id, voice: voice, pace: pace)
    }
    private var serviceBusy: Bool { narrations.isPreparing || narrations.preparationOwner != nil }
    private var lifetime: NarrationTranslationLifetime? { preparation.discourseID == discourseID ? preparation.lifetime : nil }
    private var stage: NarrationPreparationStage { preparation.stage }
    private var currentSelectionDocument: NarrationDocument? {
        if let featuredVariant { return featuredVariant }
        guard let selection else { return nil }
        return variants.first { TranslatedListening.isSameVersion($0.selection, selection) }
    }
    /// Preparation of the version on screen, as opposed to another voice or discourse.
    private var isPreparingShownVersion: Bool {
        guard lifetime != nil, let running = preparation.selection else { return false }
        if let document = currentSelectionDocument { return TranslatedListening.isSameVersion(document.selection, running) }
        return selection.map { TranslatedListening.isSameVersion($0, running) } ?? false
    }
    /// Something else is being prepared; listening to this version will pause it.
    private var isPreparingOtherVersion: Bool { (preparation.isRunning || serviceBusy) && !isPreparingShownVersion }
    /// What preparing the rest of the shown version would use, if its voice is still installed.
    private var shownVersionSelection: NarrationSelection? {
        guard let document = currentSelectionDocument else { return selection }
        let installed = languages.contains { $0.voices.contains { $0.id == document.selection.voice.id } }
        return installed ? document.selection : nil
    }

    var body: some View {
        NavigationStack {
            Group {
                if let readingDocument {
                    TranslatedNarrationReader(
                        document: readingDocument, canReturnToOriginal: originalAudioURL != nil && entry != nil,
                        play: { play(readingDocument) }, playFrom: { play(readingDocument, from: $0) },
                        returnToOriginal: returnToOriginal
                    )
                    .id(readingDocument.id)
                    .environment(player)
                } else {
                    preparationList
                }
            }
            .navigationTitle("Listen in Translation")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                if let failure = player.narrationPlaybackFailure {
                    NarrationPlaybackFailureBanner(failure: failure) {
                        readingDocument = nil
                        cacheReloadGeneration += 1
                    }
                    .disabled(!deletingIDs.isEmpty)
                }
            }
            .toolbar {
                if readingDocument != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Listening", systemImage: "chevron.left") { readingDocument = nil }
                            .accessibilityIdentifier("narration.showVariants")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: close)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("narration.done")
                }
            }
        }
        .tint(UserSettings.shared.effectiveAccentTheme.color)
        .presentationDragIndicator(.visible)
        .background {
            EscapeKeyHandler(action: close)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .task(id: "\(discourseID):\(cacheReloadGeneration)") { await loadCachedNarrations() }
        .onAppear {
            isVisible = true
            EngagementService.shared.registerNarrationPresentation(owner: presentationOwner)
            originalAudioURL = downloads.localFileURL(for: discourseID)
            if cacheLoaded, readingDocument == nil, languages.isEmpty { refreshLanguages() }
            updateIdleTimer()
        }
        .onDisappear {
            isVisible = false
            NarrationVoicePreview.shared.stop(ownerID: presentationOwner)
            availabilityTask?.cancel()
            availabilityRequestID = nil
            loadingLanguages = false
            updateIdleTimer()
            EngagementService.shared.unregisterNarrationPresentation(owner: presentationOwner)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { NarrationVoicePreview.shared.stop(ownerID: presentationOwner) }
            if phase == .active {
                refreshCachedAudio()
                originalAudioURL = downloads.localFileURL(for: discourseID)
                if readingDocument == nil, languages.isEmpty, !loadingLanguages { refreshLanguages() }
            }
            updateIdleTimer()
        }
        .onChange(of: narrations.documents) { _, _ in refreshCachedAudio() }
        .onChange(of: serviceBusy) { _, busy in
            if !busy, readingDocument == nil, languages.isEmpty, !loadingLanguages { refreshLanguages() }
        }
        .onChange(of: downloads.downloadedIDs) { _, _ in
            originalAudioURL = downloads.localFileURL(for: discourseID)
        }
        .onChange(of: player.isPlaying) { _, playing in
            if playing { NarrationVoicePreview.shared.stop(ownerID: presentationOwner) }
            updateIdleTimer()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)) { _ in
            if readingDocument == nil { refreshLanguages() }
        }
        .onChange(of: player.currentNarration) { _, document in
            updateIdleTimer()
        }
        .onChange(of: readingDocument) { _, document in
            if document == nil, languages.isEmpty, !loadingLanguages { refreshLanguages() }
            updateIdleTimer()
        }
    }

    private var preparationList: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    if let entry {
                        SeriesThumbnailView(name: entry.series.name, size: 60, seriesID: entry.series.id)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry?.discourse.displayTitle ?? "Saved Discourse").font(.headline)
                        if let sourceLanguage {
                            Text("Original in \(NarrationLanguageSupport.displayName(for: sourceLanguage))")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
                if sourceLanguage != nil, transcripts.availability(for: discourseID) != .unavailable {
                    Button("Refresh languages and voices", systemImage: "arrow.clockwise", action: refreshLanguages)
                        .font(.footnote).disabled(loadingLanguages)
                        .accessibilityIdentifier("narration.refreshLanguages")
                }
                if cacheLoaded, !showsOptions, let shown = shownSelection {
                    versionSummary(shown)
                }
            }
            if !cacheLoaded {
                Section { ProgressView("Loading…") }
            } else {
                if sourceLanguage == nil {
                    Section {
                        Text("This discourse is no longer in the catalog. Its saved translation can't be opened in the player.")
                            .accessibilityIdentifier("narration.missingDiscourse")
                    }
                } else if transcripts.availability(for: discourseID) == .unavailable {
                    Section {
                        Label("No transcript yet", systemImage: "doc.plaintext").font(.headline)
                            .accessibilityIdentifier("narration.noTranscript")
                        Text("This discourse needs a source transcript before it can be translated.").font(.footnote)
                    }
                } else if showsOptions {
                    languageControls
                }
            }
            if cacheLoaded, sourceLanguage != nil, transcripts.availability(for: discourseID) != .unavailable,
               currentSelectionDocument != nil || selection != nil {
                listenCard
            }
            if isPreparingOtherVersion {
                Section {
                    Label(otherPreparationDescription, systemImage: "hourglass")
                        .font(.footnote).accessibilityIdentifier("narration.busy")
                    if preparation.isRunning {
                        Button("Pause it", systemImage: "pause.circle") { preparation.pause() }
                            .font(.footnote).accessibilityIdentifier("narration.pauseOther")
                    }
                }
            }
            if let failure = errorMessage ?? (preparation.discourseID == discourseID ? preparation.errorMessage : nil) {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.footnote).textSelection(.enabled).accessibilityIdentifier("narration.preparationError")
                }
            }
            if !variants.isEmpty {
                Section {
                    DisclosureGroup {
                        ForEach(variants) { savedNarrationRow($0) }
                    } label: {
                        Text("Saved translations (\(variants.count))").accessibilityIdentifier("narration.savedVersions")
                    }
                }
            }
            if let cacheError {
                Section {
                    Text(cacheError).font(.footnote).foregroundStyle(.orange)
                    Button("Reload saved translations") { cacheReloadGeneration += 1 }.disabled(serviceBusy)
                }
            }
            Section {
                Text("A system voice reads the translation, not Osho. Wording and pronunciation may be inaccurate.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("narration.explanation")
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.bottom, 24, for: .scrollContent)
        .accessibilityIdentifier("narration.preparation")
        .confirmationDialog(
            "Delete this translation?", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible, presenting: pendingDeletion
        ) { document in
            Button("Delete", role: .destructive) { delete(document) }
                .accessibilityIdentifier("narration.confirmDelete")
        } message: { document in
            Text("\(NarrationLanguageSupport.displayName(for: document.selection.targetLanguage)) · \(document.selection.voice.narrationDisplayName). It would need to be prepared again to listen.")
        }
    }

    @ViewBuilder
    private var transport: some View {
        VStack(spacing: 4) {
            Slider(value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                   in: 0...max(1, player.duration))
                .accessibilityLabel("Playback position")
            HStack {
                Button { player.skipBackward() } label: { Image(systemName: "gobackward.15").frame(width: 44, height: 44) }
                    .accessibilityLabel("Skip back 15 seconds").accessibilityIdentifier("narration.skipBack")
                Spacer()
                Text(Duration.seconds(player.currentTime), format: .time(pattern: .minuteSecond)).monospacedDigit()
                    .accessibilityIdentifier("narration.elapsed")
                Text("/").foregroundStyle(.tertiary).accessibilityHidden(true)
                Text(Duration.seconds(max(player.duration, 0)), format: .time(pattern: .minuteSecond))
                    .monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button { player.skipForward() } label: { Image(systemName: "goforward.30").frame(width: 44, height: 44) }
                    .accessibilityLabel("Skip forward 30 seconds").accessibilityIdentifier("narration.skipForward")
            }
        }
        .buttonStyle(.borderless)
        HStack {
            Button { showSpeed = true } label: {
                compactLabel("Speed \(PlaybackSpeed.label(player.playbackRate))", systemImage: "speedometer", singleLine: true)
                    .frame(minHeight: 44)
            }
            .popover(isPresented: $showSpeed) { PlaybackSpeedControl().environment(player) }
            .accessibilityLabel("Playback speed")
            .accessibilityValue(PlaybackSpeed.accessibilityLabel(player.playbackRate))
            .accessibilityIdentifier("narration.speed")
            Spacer()
            Button { showSleepTimer = true } label: {
                compactLabel(SleepTimerService.shared.isActive ? SleepTimerService.shared.statusLabel : "Sleep timer",
                             systemImage: SleepTimerService.shared.isActive ? "moon.fill" : "moon", singleLine: true)
                    .frame(minHeight: 44)
            }
            .popover(isPresented: $showSleepTimer) { SleepTimerControl { showSleepTimer = false } }
            .accessibilityLabel("Sleep timer")
            .accessibilityValue(SleepTimerService.shared.isActive ? SleepTimerService.shared.statusLabel : "Off")
            .accessibilityIdentifier("narration.sleepTimer")
        }
        .buttonStyle(.borderless)
        .font(.subheadline)
    }

    /// Language, voice and pace fold into one line once there is a version to play or translate.
    private var showsOptions: Bool { showOptions || (currentSelectionDocument == nil && !isPreparingShownVersion) }
    private var canHideOptions: Bool { currentSelectionDocument != nil || isPreparingShownVersion }
    private var shownSelection: NarrationSelection? { currentSelectionDocument?.selection ?? selection }
    private var hasReadyAudio: Bool {
        guard let document = currentSelectionDocument, !document.segments.isEmpty else { return false }
        return !document.isComplete || playableIDs.contains(document.id)
    }
    private var isLoadedHere: Bool {
        currentSelectionDocument.map { player.currentNarration?.id == $0.id } ?? false
    }

    private func versionSummary(_ shown: NarrationSelection) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(NarrationLanguageSupport.displayName(for: shown.targetLanguage)).font(.subheadline.weight(.semibold))
                Text("\(shown.voice.narrationDisplayName) · \(shown.pace.label)").font(.footnote).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("narration.versionSummary")
            Spacer(minLength: 8)
            Button("Change") {
                NarrationVoicePreview.shared.stop(ownerID: presentationOwner)
                showOptions = true
            }
            .buttonStyle(.bordered).controlSize(.small)
            .accessibilityLabel("Change language, voice or pace")
            .accessibilityIdentifier("narration.changeOptions")
        }
    }

    /// Two actions, each doing only what it says: Play what is ready, and translate the rest.
    private var listenCard: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(statusTitle).font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("narration.listenStatus")
                if let fraction = readyFraction, fraction < 1 {
                    ProgressView(value: fraction).accessibilityHidden(true)
                }
                if let statusDetail {
                    Text(statusDetail).font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("narration.statusDetail")
                }
            }
            .padding(.vertical, 2)
            if hasReadyAudio {
                Button(action: togglePlay) {
                    compactLabel(playLabel, systemImage: isSelectionPlaying ? "pause.fill" : "play.fill")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!deletingIDs.isEmpty)
                .accessibilityIdentifier("narration.play")
            }
            if let translateLabel {
                Label(Self.backgroundLimit, systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("narration.backgroundLimit")
                if hasReadyAudio {
                    translateButton(translateLabel).buttonStyle(.bordered)
                } else {
                    translateButton(translateLabel).buttonStyle(.borderedProminent)
                }
            }
            if isLoadedHere { transport }
            if hasReadyAudio, let document = currentSelectionDocument {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { secondaryActions(document); Spacer(minLength: 0) }
                    VStack(alignment: .leading, spacing: 8) { secondaryActions(document) }
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
        } footer: {
            if translateLabel != nil {
                Label(Self.heatWarning, systemImage: "thermometer.medium")
                    .accessibilityIdentifier("narration.heatWarning")
            }
        }
    }

    private func translateButton(_ label: (title: String, icon: String)) -> some View {
        Button(action: translateShownVersion) {
            compactLabel(label.title, systemImage: label.icon)
                .font(hasReadyAudio ? .subheadline : .headline).frame(maxWidth: .infinity, minHeight: hasReadyAudio ? 32 : 44)
        }
        .disabled(!canTranslate)
        .accessibilityIdentifier("narration.translate")
    }

    @ViewBuilder
    private func secondaryActions(_ document: NarrationDocument) -> some View {
        Button { readingDocument = document } label: { compactLabel("Read along", systemImage: "text.alignleft", singleLine: true) }
            .accessibilityIdentifier("narration.readAlong")
        if originalAudioURL != nil {
            Button(action: returnToOriginal) { compactLabel("Osho's recording", systemImage: "waveform", singleLine: true) }
                .accessibilityLabel("Switch to Osho's recording")
                .accessibilityIdentifier("narration.returnToOriginal")
        }
    }

    /// List rows give a Label a wide icon column; these keep the icon beside the title.
    /// One line lets ViewThatFits stack the small buttons instead of wrapping them.
    private func compactLabel(_ title: String, systemImage: String, singleLine: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).accessibilityHidden(true)
            Text(title).lineLimit(singleLine ? 1 : nil).multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
    }

    private var playLabel: String {
        if isSelectionPlaying { return "Pause" }
        if isLoadedHere, player.narrationPlaybackFailure == nil { return "Resume" }
        return "Play"
    }

    private var translateLabel: (title: String, icon: String)? {
        if isPreparingShownVersion { return ("Pause translating", "pause.circle") }
        guard let document = currentSelectionDocument, !document.segments.isEmpty else {
            guard let target = shownSelection?.targetLanguage else { return nil }
            return ("Translate into \(NarrationLanguageSupport.displayName(for: target))", "globe")
        }
        if document.isComplete { return playableIDs.contains(document.id) ? nil : ("Translate again", "arrow.clockwise") }
        return ("Continue translating", "globe")
    }

    private var canTranslate: Bool {
        guard deletingIDs.isEmpty else { return false }
        return isPreparingShownVersion || shownVersionSelection != nil
    }

    private var readyFraction: Double? {
        guard let document = currentSelectionDocument, document.expectedSegmentCount > 0 else { return nil }
        return Double(document.segments.count) / Double(document.expectedSegmentCount)
    }

    private var statusTitle: String {
        guard let document = currentSelectionDocument, !document.segments.isEmpty else {
            return isPreparingShownVersion ? "Translating…" : "Not prepared yet"
        }
        if document.isComplete { return playableIDs.contains(document.id) ? "Saved · plays offline" : "Saved audio is missing" }
        return NarrationTimeFormatting.passages(document.segments.count, of: document.expectedSegmentCount) + " ready"
    }

    private var statusDetail: String? {
        if isPreparingShownVersion {
            guard stage == .creatingAudio, narrations.preparingDiscourseID == discourseID else { return stage.label }
            let remaining = narrations.estimatedSecondsRemaining.map(NarrationTimeFormatting.remaining) ?? "Estimating time…"
            return hasReadyAudio ? "Translating the rest · \(remaining)" : "Translating · \(remaining)"
        }
        guard let document = currentSelectionDocument, !document.segments.isEmpty else {
            return "You can play as soon as the first passage is ready. The audio stays on this device."
        }
        if document.isComplete {
            return playableIDs.contains(document.id) ? nil : "Translate again to listen."
        }
        if shownVersionSelection == nil, !languages.isEmpty {
            return "\(document.selection.voice.narrationDisplayName) isn't on this device any more, so the rest can't be translated. Choose another voice."
        }
        guard let stop = preparation.stopExplanation(discourseID: discourseID, selection: document.selection) else { return "Paused" }
        let time = stop.at.formatted(date: Calendar.current.isDateInToday(stop.at) ? .omitted : .abbreviated, time: .shortened)
        return "\(stop.reason.explanation) at \(time)."
    }

    static let heatWarning = "Translating uses a lot of processing power. Your phone may get warm, and the battery may drain faster."

    /// iOS gives about 30 seconds after the app leaves the screen; playing audio keeps it running.
    static let backgroundLimit = "iOS stops translating soon after you leave the app or lock the phone. If you play the translation, it keeps translating in the background. When you come back, it continues from where it stopped."

    private func togglePlay() {
        NarrationVoicePreview.shared.stop(ownerID: presentationOwner)
        errorMessage = nil
        guard let document = currentSelectionDocument, !document.segments.isEmpty else { return }
        if player.currentNarration?.id == document.id, player.isPlaying {
            player.togglePlayPause()
            return
        }
        play(document)
    }

    private func translateShownVersion() {
        NarrationVoicePreview.shared.stop(ownerID: presentationOwner)
        errorMessage = nil
        if isPreparingShownVersion {
            cancelPreparation()
            return
        }
        if let document = currentSelectionDocument, document.isComplete, !playableIDs.contains(document.id) {
            delete(document, prepareAgain: true)
            return
        }
        guard let target = shownVersionSelection else { return }
        ensurePreparing(target, autoPlay: false)
    }

    private var otherPreparationDescription: String {
        let other = preparation.discourseID.flatMap { Catalog.discourseLookup[$0]?.discourse.displayTitle }
        let what = preparation.discourseID == discourseID ? "Another voice of this discourse" : (other ?? "Another discourse")
        return "\(what) is being translated." + (translateLabel != nil && !isPreparingShownVersion
            ? " Translating this one pauses it." : "")
    }

    private func savedNarrationRow(_ document: NarrationDocument) -> some View {
        let shown = currentSelectionDocument?.id == document.id
        return HStack(spacing: 12) {
            Button {
                selectSaved(document)
            } label: {
                HStack {
                    SavedNarrationLabel(document: document, isPlayable: playableIDs.contains(document.id))
                    Spacer()
                    Image(systemName: "checkmark").foregroundStyle(.tint).opacity(shown ? 1 : 0)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(shown ? .isSelected : [])
            .accessibilityHint("Shows this version above, ready to listen")
            .accessibilityIdentifier("narration.choose.\(document.id)")
            Button(role: .destructive) { pendingDeletion = document } label: {
                Image(systemName: "trash").frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .disabled(!deletingIDs.isEmpty)
            .accessibilityLabel("Delete")
            .accessibilityIdentifier("narration.delete.\(document.id)")
        }
    }

    private var languageControls: some View {
        Section {
            if loadingLanguages {
                ProgressView("Checking languages and voices…")
                    .accessibilityIdentifier("narration.checkingLanguages")
            } else if languages.isEmpty {
                if let availabilityError {
                    Label("Couldn't check languages", systemImage: "globe").font(.headline)
                        .accessibilityIdentifier("narration.availabilityError")
                    Text(availabilityError).font(.footnote)
                } else if languagesChecked {
                    Label("Translation unavailable", systemImage: "globe").font(.headline)
                        .accessibilityIdentifier("narration.unavailable")
                    Text("Apple Translation doesn't offer a translation from this source language on this device.")
                        .font(.footnote)
                } else {
                    Text("Check the available languages and voices to translate this discourse.").font(.footnote)
                }
            } else {
                Picker("Language", selection: Binding(
                    get: { selectedLanguageID },
                    set: { id in
                        featuredVariantID = nil
                        selectedLanguageID = id
                        let voices = languages.first { $0.id == id }?.voices ?? []
                        selectedVoiceID = NarrationVoicePreferences.preferredVoiceID(for: id, voices: voices) ?? voices.first?.id ?? ""
                        if let series = entry?.series { TranslatedListening.setTargetLanguage(id, for: series) }
                    }
                )) {
                    Text("Choose a language").tag("")
                    ForEach(languages) { Text($0.displayName).tag($0.id) }
                }
                .accessibilityIdentifier("narration.targetLanguage")
                if let language = selectedLanguage {
                    if language.voices.isEmpty {
                        Text("No voice for \(language.displayName) is on this iPhone yet. Download one in Apple's **Settings** app under **Accessibility › Read & Speak › Voices**, then come back.")
                            .font(.footnote).accessibilityIdentifier("narration.noVoice")
                    } else {
                        NavigationLink {
                            NarrationVoicePicker(voices: language.voices, selectedVoiceID: voiceChoice,
                                                 sampleText: previewSample(for: language.id), pace: pace)
                                .environment(player)
                        } label: {
                            LabeledContent("Voice", value: currentSelectionDocument?.selection.voice.narrationDisplayName
                                           ?? language.voices.first { $0.id == selectedVoiceID }?.narrationDisplayName ?? "Choose a voice")
                        }
                        .accessibilityIdentifier("narration.voice")
                        if let voice = language.voices.first(where: { $0.id == selectedVoiceID }) {
                            let preview = NarrationVoicePreview.shared
                            let previewing = preview.ownerID == presentationOwner && preview.activeVoiceID == voice.id
                            Button {
                                if previewing {
                                    preview.stop(ownerID: presentationOwner)
                                } else {
                                    preview.play(voice: voice, sampleText: previewSample(for: voice.language),
                                                 pace: pace, ownerID: presentationOwner) {
                                        player.setPlaying(false)
                                    }
                                }
                            } label: {
                                Label(previewing ? "Stop preview" : "Preview voice", systemImage: previewing ? "stop.circle" : "play.circle")
                                    .frame(minHeight: 44)
                            }
                            .accessibilityIdentifier("narration.previewVoice")
                            if let failure = preview.failure, failure.ownerID == presentationOwner {
                                Text(failure.message).font(.footnote).foregroundStyle(.orange)
                                    .accessibilityIdentifier("narration.previewError")
                            }
                        }
                    }
                    Picker("Pace", selection: Binding(get: { pace }, set: {
                        featuredVariantID = nil
                        pace = $0
                        UserDefaults.standard.set($0.rawValue, forKey: NarrationPace.preferenceKey)
                    })) {
                        ForEach(NarrationPace.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .accessibilityIdentifier("narration.pace")
                    if language.support.status != .installed {
                        Text("Apple may ask to download this language before listening.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let availabilityError { Text(availabilityError).font(.footnote).foregroundStyle(.orange) }
            }
            if !loadingLanguages { moreLanguagesAndVoices }
        } header: {
            if canHideOptions {
                HStack {
                    Text("Language and voice")
                    Spacer()
                    Button("Hide") { showOptions = false }
                        .font(.subheadline).textCase(nil)
                        .accessibilityLabel("Hide language and voice")
                        .accessibilityIdentifier("narration.hideOptions")
                }
            }
        }
    }

    /// Neither list is the app's own: languages come from Apple Translation and voices from iOS.
    private var moreLanguagesAndVoices: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text("**More voices:** voices come from iOS, so you download them in Apple's **Settings** app, not in Osho Talks. Open **Settings › Accessibility › Read & Speak › Voices**, choose a language and download a voice. Enhanced and Premium voices sound more natural. Then come back and tap Refresh languages and voices.")
                Text("**More languages:** this list shows every language Apple Translation offers from \(sourceLanguage.map(NarrationLanguageSupport.displayName(for:)) ?? "this talk's language"). Apple adds languages in iOS updates. To download a language before you translate, open Apple's **Settings** app, then **Apps › Translate › Languages**.")
            }
            .font(.footnote).foregroundStyle(.secondary)
            .padding(.vertical, 4)
        } label: {
            Label("Get more languages and voices", systemImage: "questionmark.circle").font(.subheadline)
        }
        .accessibilityIdentifier("narration.moreLanguagesAndVoices")
    }

    /// A saved passage in the voice's own language, so the preview sounds like listening will.
    private func previewSample(for language: String) -> String? {
        let script = NarrationLanguageSupport.languageAndScript(for: language)
        return variants.first { NarrationLanguageSupport.languageAndScript(for: $0.selection.targetLanguage) == script }?
            .segments.first?.text
    }

    private var voiceChoice: Binding<String> {
        Binding(get: { selectedVoiceID }, set: {
            NarrationVoicePreview.shared.stop(ownerID: presentationOwner)
            featuredVariantID = nil
            selectedVoiceID = $0
            NarrationVoicePreferences.setPreferredVoiceID($0, for: selectedLanguageID)
        })
    }

    private var isSelectionPlaying: Bool {
        currentSelectionDocument?.id == player.currentNarration?.id && player.currentNarration != nil && player.isPlaying
    }

    private func loadCachedNarrations() async {
        let firstLoad = !cacheLoaded
        await narrations.load()
        guard !Task.isCancelled else { return }
        refreshCachedAudio()
        cacheLoaded = true
        cacheError = narrations.errorMessage
        if firstLoad {
            if featuredVariant == nil {
                // Open on what can already be heard: the playing version, the one being prepared, or the best saved one.
                let playing = player.currentNarration.flatMap { $0.discourseID == discourseID ? $0.id : nil }
                // Preflight and language consent run before the prepared document exists.
                let preparingSelection = preparation.isRunning && preparation.discourseID == discourseID ? preparation.selection : nil
                let preparing = preparingSelection.flatMap { running in
                    variants.first { TranslatedListening.isSameVersion($0.selection, running) }?.id
                }
                // A language chosen on the series page wins; any language only when none was chosen.
                let saved = preferredTargetLanguage.map {
                    TranslatedListening.savedNarration(for: discourseID, target: $0, in: narrations.documents)
                } ?? TranslatedListening.savedNarration(for: discourseID, in: narrations.documents)
                featuredVariantID = playing ?? preparing ?? (preparingSelection == nil ? saved?.id : nil)
            }
            if let featuredVariant {
                selectedLanguageID = featuredVariant.selection.targetLanguage
                selectedVoiceID = featuredVariant.selection.voice.id
                pace = featuredVariant.selection.pace
            } else if preparation.discourseID == discourseID, let selection = preparation.selection {
                selectedLanguageID = selection.targetLanguage
                selectedVoiceID = selection.voice.id
                pace = selection.pace
            }
        }
        if readingDocument == nil { refreshLanguages() }
    }

    private func refreshCachedAudio() { playableIDs = NarrationCachePresentation.playableIDs(in: variants) }

    private func refreshLanguages() {
        guard isVisible, scenePhase == .active, let sourceLanguage,
              transcripts.availability(for: discourseID) != .unavailable else { return }
        availabilityTask?.cancel()
        let requestID = UUID()
        availabilityRequestID = requestID
        loadingLanguages = true
        availabilityError = nil
        let voices = NativeNarrationSpeechRenderer.availableVoices()
        availabilityTask = Task {
            do {
                let options = try await NarrationLanguageSupport.availableLanguages(sourceLanguage: sourceLanguage, voices: voices)
                guard !Task.isCancelled, availabilityRequestID == requestID else { return }
                languages = options
                languagesChecked = true
                if selectedLanguageID.isEmpty, let preferredTargetLanguage,
                   let preferred = options.first(where: {
                       NarrationLanguageSupport.languageAndScript(for: $0.id)
                           == NarrationLanguageSupport.languageAndScript(for: preferredTargetLanguage)
                   }) {
                    selectedLanguageID = preferred.id
                }
                if let featuredVariant {
                    selectedLanguageID = options.first(where: {
                        NarrationLanguageSupport.languageAndScript(for: $0.id)
                            == NarrationLanguageSupport.languageAndScript(for: featuredVariant.selection.targetLanguage)
                    })?.id ?? featuredVariant.selection.targetLanguage
                    selectedVoiceID = featuredVariant.selection.voice.id
                    pace = featuredVariant.selection.pace
                    loadingLanguages = false
                    return
                }
                if selectedVoiceID.isEmpty, let language = options.first(where: { $0.id == selectedLanguageID }) {
                    selectedVoiceID = NarrationVoicePreferences.preferredVoiceID(for: language.id, voices: language.voices) ?? ""
                }
                let choice = NarrationSelectionPresentation.choice(
                    sourceLanguage: sourceLanguage, languages: options,
                    languageID: selectedLanguageID, voiceID: selectedVoiceID,
                    saved: narrations.documents, preferredDocumentID: featuredVariantID
                )
                selectedLanguageID = choice.languageID
                selectedVoiceID = choice.voiceID
                if selectedLanguageID.isEmpty {
                    let preferred = entry.map { TranslatedListening.targetLanguage(for: $0.series) }
                    let target = options.first { $0.id == preferred } ?? options.first
                    selectedLanguageID = target?.id ?? ""
                    selectedVoiceID = target.map {
                        NarrationVoicePreferences.preferredVoiceID(for: $0.id, voices: $0.voices) ?? $0.voices.first?.id ?? ""
                    } ?? ""
                }
            } catch {
                guard !Task.isCancelled, availabilityRequestID == requestID else { return }
                availabilityError = "Couldn't check translation languages. Please try again."
                Self.log.error("Availability outcome=failed")
            }
            if availabilityRequestID == requestID { loadingLanguages = false }
        }
    }

    private func selectSaved(_ document: NarrationDocument) {
        NarrationVoicePreview.shared.stop(ownerID: presentationOwner)
        featuredVariantID = document.id
        selectedLanguageID = document.selection.targetLanguage
        selectedVoiceID = document.selection.voice.id
        pace = document.selection.pace
    }

    /// One preparation runs at a time; asking for another version pauses the one running.
    private func ensurePreparing(_ requested: NarrationSelection, autoPlay: Bool = true) {
        guard isVisible, scenePhase == .active, let hostID else { return }
        if preparation.isRunning {
            if preparation.discourseID == discourseID, let running = preparation.selection,
               TranslatedListening.isSameVersion(running, requested) { return }
            preparation.pause()
        }
        guard !serviceBusy else {
            errorMessage = "Another preparation is still stopping. Try again in a moment."
            return
        }
        errorMessage = nil
        cacheError = nil
        preparation.start(discourseID: discourseID, selection: requested, hostID: hostID, player: player, listen: autoPlay)
        updateIdleTimer()
    }

    private func cancelPreparation() {
        guard preparation.discourseID == discourseID else { return }
        preparation.pause()
        updateIdleTimer()
    }

    private func updateIdleTimer() {
        ScreenAwakeService.shared.setAwake(NarrationPlaybackPresentation.keepsScreenAwake(
            isVisible: isVisible, scenePhase: scenePhase, isPreparing: lifetime != nil,
            reading: readingDocument, current: player.currentNarration, isPlaying: player.isPlaying
        ), owner: presentationOwner)
    }

    private func close() {
        dismiss()
    }

    private func play(_ requested: NarrationDocument) {
        guard deletingIDs.isEmpty, entry != nil else { return }
        let document = narrations.documents.first { $0.id == requested.id } ?? requested
        if !document.isComplete {
            playFinishedPassages(of: document)
            return
        }
        guard let url = NarrationCachePresentation.audioURL(for: document) else {
            refreshCachedAudio()
            readingDocument = nil
            cacheReloadGeneration += 1
            errorMessage = "The saved audio is missing or unreadable. Continue translating to rebuild it."
            return
        }
        switch NarrationPlaybackPresentation.action(
            for: document, current: player.currentNarration, isPlaying: player.isPlaying,
            hasFailure: player.narrationPlaybackFailure != nil
        ) {
        case .load:
            Task { await TranslatedListening.play(document, url: url, player: player) }
        case .resume: player.togglePlayPause()
        case .readAlong: break
        }
    }

    /// Starts at a chosen passage, ignoring the saved position and the recording's matching moment.
    private func play(_ requested: NarrationDocument, from position: TimeInterval) {
        guard deletingIDs.isEmpty, entry != nil else { return }
        NarrationVoicePreview.shared.stop(ownerID: presentationOwner)
        let document = narrations.documents.first { $0.id == requested.id } ?? requested
        if document.isComplete, let url = NarrationCachePresentation.audioURL(for: document) {
            narrations.savePosition(documentID: document.id, position: position)
            player.playNarration(document, url: url)
        } else {
            NarrationPreviewPlayback.shared.play(documentID: document.id, player: player, resumeAt: position)
        }
    }

    private func playFinishedPassages(of document: NarrationDocument) {
        if player.currentNarration?.id == document.id, player.narrationPlaybackFailure == nil {
            // At the end of the finished passages, resuming continues with any newer ones.
            if !player.isPlaying { player.togglePlayPause() }
        } else {
            let loadedTrack = player.currentTrackId
            Task {
                let start = await TranslatedListening.translatedStart(for: document, player: player)
                guard player.currentTrackId == loadedTrack else { return }
                NarrationPreviewPlayback.shared.play(documentID: document.id, player: player, resumeAt: start)
            }
        }
    }

    private func delete(_ document: NarrationDocument, prepareAgain: Bool = false) {
        guard deletingIDs.isEmpty else { return }
        deletingIDs.insert(document.id)
        Task {
            defer { deletingIDs.remove(document.id) }
            do {
                try await preparation.delete(document, player: player)
                if readingDocument?.id == document.id { readingDocument = nil }
                if featuredVariantID == document.id { featuredVariantID = nil }
                errorMessage = nil
                if prepareAgain {
                    deletingIDs.remove(document.id)
                    ensurePreparing(document.selection, autoPlay: false)
                }
            } catch {
                errorMessage = "Couldn't delete the saved translation. Please try again."
                Self.log.error("Cache deletion outcome=failed")
            }
        }
    }

    private func returnToOriginal() {
        guard let entry else { return }
        guard let url = downloads.localFileURL(for: discourseID) else {
            originalAudioURL = nil
            return
        }
        let title = entry.discourse.displayTitle, series = entry.series.name
        guard let narration = player.currentNarration, narration.discourseID == discourseID else {
            player.returnToOriginal(localURL: url, id: discourseID, title: title, series: series)
            dismiss()
            return
        }
        let translatedTime = player.currentTime
        Task {
            // Resume the recording where the translation was, not where the recording last stopped.
            let original = await narrations.timeline(for: narration)?.originalTime(forTranslated: translatedTime)
            guard player.currentNarration?.id == narration.id else { return }
            player.returnToOriginal(localURL: url, id: discourseID, title: title, series: series, at: original)
            dismiss()
        }
    }

}

@available(macCatalyst 26.0, *)
enum NarrationSelectionPresentation {
    static func choice(
        sourceLanguage: String, languages: [NarrationLanguageOption], languageID: String, voiceID: String,
        saved: [NarrationDocument], preferredDocumentID: String? = nil
    ) -> (languageID: String, voiceID: String) {
        let available = languages.filter {
            ($0.support.status == .installed || $0.support.status == .supported)
                && !NarrationLanguageSupport.isSameLanguage(sourceLanguage, $0.id)
        }
        if let language = available.first(where: { $0.id == languageID }) {
            return (language.id, language.voices.first { $0.id == voiceID }?.id ?? language.voices.first?.id ?? "")
        }
        let recent = saved.sorted {
            if ($0.id == preferredDocumentID) != ($1.id == preferredDocumentID) { return $0.id == preferredDocumentID }
            return $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
        }
        for document in recent {
            let target = NarrationLanguageSupport.languageAndScript(for: document.selection.targetLanguage)
            guard let language = available.first(where: { NarrationLanguageSupport.languageAndScript(for: $0.id) == target }),
                  let voice = language.voices.first(where: { $0.id == document.selection.voice.id }),
                  NarrationLanguageSupport.languageAndScript(for: voice.language) == target else { continue }
            return (language.id, voice.id)
        }
        return ("", "")
    }
}

enum NarrationPlaybackPresentation {
    enum Action: Equatable { case load, resume, readAlong }

    static func action(for document: NarrationDocument, current: NarrationDocument?, isPlaying: Bool, hasFailure: Bool) -> Action {
        guard current == document, !hasFailure else { return .load }
        return isPlaying ? .readAlong : .resume
    }

    static func keepsScreenAwake(
        isVisible: Bool, scenePhase: ScenePhase, isPreparing: Bool,
        reading: NarrationDocument?, current: NarrationDocument?, isPlaying: Bool
    ) -> Bool {
        guard isVisible, scenePhase == .active else { return false }
        return isPreparing || (reading != nil && reading == current && isPlaying)
    }

    struct Following {
        var isFollowing = true
        private var interactionStartOffset: CGFloat?

        mutating func scrollPhaseChanged(from old: ScrollPhase, to phase: ScrollPhase, offset: CGFloat) {
            // Touch-down also starts `.interacting`; only meaningful movement or a fling stops following.
            switch phase {
            case .interacting: interactionStartOffset = offset
            case .decelerating:
                isFollowing = false
                interactionStartOffset = nil
            default:
                if old == .interacting, let start = interactionStartOffset, abs(offset - start) > 24 { isFollowing = false }
                interactionStartOffset = nil
            }
        }
    }
}

struct NarrationPlaybackFailureBanner: View {
    let failure: AudioPlayerService.NarrationPlaybackFailure
    let recover: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(failure.label, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            Button("Rebuild Translation", systemImage: "arrow.clockwise", action: recover)
                .frame(minHeight: 44)
                .accessibilityIdentifier("narration.recoverPlayback")
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial)
        .accessibilityIdentifier("narration.playbackFailure")
    }
}

@MainActor
private enum NarrationCachePresentation {
    static func audioURL(for document: NarrationDocument) -> URL? {
        guard document.isComplete, let url = NarrationService.shared.audioURL(for: document),
              url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        return url
    }
    static func playableIDs(in documents: [NarrationDocument]) -> Set<String> {
        Set(documents.compactMap { audioURL(for: $0) == nil ? nil : $0.id })
    }
    static func status(for document: NarrationDocument, isPlayable: Bool) -> String {
        if isPlayable { return "Ready · Plays offline" }
        if document.isComplete { return "Audio file missing · Rebuild to listen" }
        return NarrationTimeFormatting.passages(document.segments.count, of: document.expectedSegmentCount) + " ready"
    }
}

private struct SavedNarrationLabel: View {
    let document: NarrationDocument
    let isPlayable: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(NarrationLanguageSupport.displayName(for: document.selection.targetLanguage)).font(.headline)
            Text("\(document.selection.voice.narrationDisplayName) · \(document.selection.pace.label)")
                .font(.subheadline).foregroundStyle(.secondary)
            Text(NarrationCachePresentation.status(for: document, isPlayable: isPlayable))
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private extension NarrationVoice {
    var narrationDisplayName: String {
        switch quality {
        case AVSpeechSynthesisVoiceQuality.enhanced.rawValue: "\(name) (Enhanced)"
        case AVSpeechSynthesisVoiceQuality.premium.rawValue: "\(name) (Premium)"
        default: name
        }
    }
}

private struct TranslatedNarrationReader: View {
    // Explicit anchor rows can be found before lazy layout realizes a distant passage.
    private enum Row: Identifiable {
        enum ID: Hashable { case start(Int), passage(Int) }
        case start(Int)
        case passage(NarrationSegment)
        var id: ID {
            switch self {
            case .start(let index): .start(index)
            case .passage(let segment): .passage(segment.index)
            }
        }
    }
    let document: NarrationDocument
    let canReturnToOriginal: Bool
    let play: @MainActor () -> Void
    let playFrom: @MainActor (TimeInterval) -> Void
    let returnToOriginal: @MainActor () -> Void
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable private var settings = UserSettings.shared
    @State private var following = NarrationPlaybackPresentation.Following()
    @State private var audioAvailable = true
    @State private var showSpeed = false
    @State private var showSleepTimer = false
    private let narrations = NarrationService.shared
    private let preview = NarrationPreviewPlayback.shared
    private var sleepTimer: SleepTimerService { SleepTimerService.shared }

    /// New passages keep arriving while a rendition is prepared; the reader follows the saved copy.
    private var live: NarrationDocument { narrations.documents.first { $0.id == document.id } ?? document }
    private var isCurrent: Bool { player.currentNarration?.id == document.id }
    private var isPreparingThis: Bool { narrations.preparingDocumentID == document.id }
    private var catalogEntryAvailable: Bool { Catalog.discourseLookup[document.discourseID] != nil }
    private var highlightedIndex: Int? { isCurrent ? live.segmentIndex(at: player.currentTime) : nil }
    private var accent: Color { settings.effectiveAccentTheme.color }
    private var fontSize: CGFloat { CGFloat(settings.transcriptFontSize) }
    /// A partial timeline ends at its last finished passage, not at the rendition's eventual length.
    private var playableDuration: TimeInterval {
        if isCurrent, let current = player.currentNarration, !current.isComplete { return current.duration }
        return live.duration
    }
    private var elapsed: TimeInterval {
        guard isCurrent, player.currentTime.isFinite else { return 0 }
        return min(max(0, player.currentTime), playableDuration)
    }

    var body: some View {
        let highlighted = highlightedIndex
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Catalog.discourseLookup[document.discourseID]?.discourse.displayTitle ?? "Saved Discourse")
                            .font(.headline)
                        SavedNarrationLabel(document: live, isPlayable: live.isComplete && audioAvailable)
                        if catalogEntryAvailable {
                            Text("A synthetic voice reads the translation. Tap a passage to play from its start.")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Text("This discourse is no longer in the catalog. You can still read its saved translation, but playback is unavailable.")
                                .font(.footnote).foregroundStyle(.secondary)
                                .accessibilityIdentifier("narration.orphanedSource")
                        }
                        if !live.isComplete { partialStatus }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 24)
                    ForEach(live.segments.flatMap { [Row.start($0.index), .passage($0)] }) { row in
                        Group {
                            switch row {
                            case .start:
                                Color.clear.frame(height: 1).accessibilityHidden(true)
                            case .passage(let segment):
                                Button {
                                    if isCurrent, player.narrationPlaybackFailure == nil {
                                        seek(toPassage: segment.index, play: true)
                                    } else {
                                        playFrom(live.startTime(forSegmentAt: segment.index))
                                    }
                                } label: {
                                    Text(segment.text)
                                        .font(.system(size: fontSize, weight: highlighted == segment.index ? .semibold : .regular))
                                        .lineSpacing(fontSize * 0.28)
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(12)
                                        .background(highlighted == segment.index ? accent.opacity(0.15) : .clear,
                                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                        .foregroundStyle(highlighted == segment.index ? accent : .primary)
                                }
                                .buttonStyle(.plain)
                                .disabled(!catalogEntryAvailable || (!isCurrent && !audioAvailable))
                                .accessibilityHint("Plays from the start of this passage")
                                .accessibilityAddTraits(highlighted == segment.index ? .isSelected : [])
                                .accessibilityIdentifier("narration.segment.\(segment.index)")
                                .padding(.bottom, 24)
                            }
                        }
                        .id(row.id)
                    }
                }
                .frame(maxWidth: contentMaxWidth)
                .padding()
                .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("narration.reader")
            .onScrollPhaseChange { old, phase, context in
                following.scrollPhaseChanged(from: old, to: phase, offset: context.geometry.contentOffset.y)
            }
            .onChange(of: highlighted, initial: true) { _, index in
                if following.isFollowing, let index { scroll(to: index, proxy: proxy) }
            }
            .onChange(of: following.isFollowing) { _, isFollowing in
                if isFollowing, let highlighted { scroll(to: highlighted, proxy: proxy) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { transportControls }
        .onAppear { refreshAvailability() }
        .onChange(of: document) { _, _ in refreshAvailability() }
        .onChange(of: narrations.documents) { _, _ in refreshAvailability() }
    }

    @ViewBuilder
    private var partialStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isPreparingThis {
                ProgressView(value: narrations.progress.isFinite ? min(1, max(0, narrations.progress)) : 0)
                    .tint(accent)
                HStack {
                    Text("Still translating · " + NarrationTimeFormatting.passages(live.segments.count, of: live.expectedSegmentCount))
                    Spacer()
                    if let remaining = narrations.estimatedSecondsRemaining {
                        Text(NarrationTimeFormatting.remaining(remaining))
                    }
                }
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            } else {
                Text("\(NarrationTimeFormatting.passages(live.segments.count, of: live.expectedSegmentCount)) ready. Go back and tap Continue translating for the rest.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if preview.waitingDocumentID == document.id {
                Label("Waiting for the next passage…", systemImage: "hourglass")
                    .font(.caption).foregroundStyle(accent)
                    .accessibilityIdentifier("narration.waitingForPassage")
            }
            if let failure = preview.failureMessage {
                Text(failure).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.top, 4)
        .accessibilityIdentifier("narration.partialStatus")
    }

    private func refreshAvailability() {
        audioAvailable = live.isComplete
            ? NarrationCachePresentation.audioURL(for: live) != nil
            : narrations.playablePrefix(of: document.id) != nil
    }

    private func seek(toPassage index: Int, play: Bool = false) {
        let start = live.startTime(forSegmentAt: index)
        if let current = player.currentNarration, !current.isComplete, index >= current.segments.count {
            // A newer passage is outside the timeline that is playing; rebuilding it also starts playback.
            preview.play(documentID: document.id, player: player, resumeAt: start)
        } else {
            player.seek(to: start)
            if play, !player.isPlaying { player.setPlaying(true) }
        }
    }

    private func scroll(to index: Int, proxy: ScrollViewProxy) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
            proxy.scrollTo(Row.ID.start(index), anchor: UnitPoint(x: 0.5, y: 0.15))
        }
    }

    private var transportControls: some View {
        VStack(spacing: 8) {
            if isCurrent {
                ProgressView(value: elapsed, total: max(playableDuration, 1))
                    .tint(accent)
                    .accessibilityLabel(live.isComplete ? "Translation progress" : "Progress through finished passages")
                    .accessibilityValue("\(formatTime(elapsed)) of \(formatTime(playableDuration))")
                    .accessibilityIdentifier("narration.playbackProgress")
                HStack {
                    Text(formatTime(elapsed))
                    Spacer()
                    Text("-" + formatTime(max(0, playableDuration - elapsed)))
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 24) {
                if isCurrent {
                    Button { player.skipBackward() } label: {
                        Image(systemName: "gobackward.15").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Skip back 15 seconds")
                    Button {
                        if player.isPlaying { player.togglePlayPause() } else { play() }
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.largeTitle).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(player.isPlaying ? "Pause translation" : "Play translation")
                    .accessibilityIdentifier("narration.togglePlayback")
                    Button { player.skipForward() } label: {
                        Image(systemName: "goforward.30").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Skip forward 30 seconds")
                } else {
                    Button(live.isComplete ? "Play Translation" : "Play Finished Part", systemImage: "play.fill", action: play)
                        .frame(minHeight: 44)
                        .disabled(!audioAvailable || !catalogEntryAvailable || preview.isLoading)
                        .accessibilityIdentifier("narration.startPlayback")
                }
            }
            .font(.title3)
            HStack {
                Button { following.isFollowing.toggle() } label: {
                    Label(isCurrent && following.isFollowing ? "Following playback" : "Follow playback", systemImage: "location.fill")
                        .frame(minHeight: 44, alignment: .leading)
                }
                .font(.footnote)
                .disabled(!isCurrent)
                .accessibilityLabel("Follow playback")
                .accessibilityValue(isCurrent && following.isFollowing ? "On" : "Off")
                .accessibilityIdentifier("narration.followPlayback")
                Spacer()
                Button { showSpeed = true } label: {
                    Text(PlaybackSpeed.label(player.playbackRate))
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(PlaybackSpeed.matches(player.playbackRate, 1) ? Color.secondary : accent)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .popover(isPresented: $showSpeed) { PlaybackSpeedControl().environment(player) }
                .accessibilityLabel("Playback speed")
                .accessibilityValue(PlaybackSpeed.accessibilityLabel(player.playbackRate))
                .accessibilityIdentifier("narration.speed")
                Button { showSleepTimer = true } label: {
                    Image(systemName: sleepTimer.isActive ? "moon.fill" : "moon")
                        .foregroundStyle(sleepTimer.isActive ? accent : Color.secondary)
                        .frame(width: 44, height: 44)
                }
                .popover(isPresented: $showSleepTimer) { SleepTimerControl { showSleepTimer = false } }
                .accessibilityLabel("Sleep timer")
                .accessibilityValue(sleepTimer.isActive ? sleepTimer.statusLabel : "Off")
                .accessibilityIdentifier("narration.sleepTimer")
                Menu {
                    Picker("Text size", selection: $settings.transcriptFontSize) {
                        ForEach(UserSettings.transcriptFontSizes, id: \.self) { size in Text("\(Int(size)) pt").tag(size) }
                    }
                } label: {
                    Image(systemName: "textformat.size").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Read-along text size")
                .accessibilityValue("\(Int(settings.transcriptFontSize)) points")
                .accessibilityIdentifier("narration.textSize")
            }
            if canReturnToOriginal {
                Button("Switch to Osho's recording", systemImage: "waveform", action: returnToOriginal)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("narration.returnToOriginal")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let seconds = seconds.isFinite ? max(0, seconds).rounded(.down) : 0
        return Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3_600 ? .hourMinuteSecond : .minuteSecond))
    }
}
#endif
