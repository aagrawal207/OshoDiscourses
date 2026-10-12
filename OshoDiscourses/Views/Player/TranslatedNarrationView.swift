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
    private let narrations = NarrationService.shared
    private let transcripts = TranscriptService.shared

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
    @State private var loadingLanguages = false
    @State private var languagesChecked = false
    @State private var availabilityError: String?
    @State private var availabilityTask: Task<Void, Never>?
    @State private var availabilityRequestID: UUID?
    @State private var startupTask: Task<Void, Never>?
    @State private var lifetime: NarrationTranslationLifetime?
    @State private var preparationOwner: UUID?
    @State private var translationJob: NarrationTranslationJob?
    @State private var stage = NarrationPreparationStage.checkingSupport
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var retrySelection: NarrationSelection?
    @State private var deletingIDs = Set<String>()
    @State private var isVisible = false
    @State private var confirmingClose = false
    @State private var presentationOwner = UUID()

    private static let log = Logger(subsystem: "com.agraabhi.oshodiscourses", category: "NarrationTranslation")

    init(discourseID: String, selectedDocumentID: String? = nil) {
        self.discourseID = discourseID
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
        return NarrationSelection(sourceLanguage: sourceLanguage, targetLanguage: target.id, voice: voice)
    }
    private var serviceBusy: Bool { narrations.isPreparing || narrations.preparationOwner != nil }
    private var isBusy: Bool { lifetime != nil || serviceBusy || !deletingIDs.isEmpty }

    var body: some View {
        NavigationStack {
            Group {
                if let readingDocument {
                    TranslatedNarrationReader(
                        document: readingDocument, canReturnToOriginal: originalAudioURL != nil && entry != nil,
                        play: { play(readingDocument) }, returnToOriginal: returnToOriginal
                    )
                    .id(readingDocument.id)
                    .environment(player)
                } else {
                    preparationList
                }
            }
            .navigationTitle("Translated Narration")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                if let failure = player.narrationPlaybackFailure {
                    NarrationPlaybackFailureBanner(failure: failure) {
                        readingDocument = nil
                        cacheReloadGeneration += 1
                    }
                    .disabled(isBusy)
                }
            }
            .toolbar {
                if readingDocument != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Narrations", systemImage: "chevron.left") { readingDocument = nil }
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
        // Swiping the sheet away would silently pause translation; Done asks first.
        .interactiveDismissDisabled(lifetime != nil)
        .confirmationDialog(
            "Pause translation?", isPresented: $confirmingClose, titleVisibility: .visible
        ) {
            Button("Pause and Close") { pauseAndClose() }
            Button("Keep Translating", role: .cancel) {}
        } message: {
            Text(narrations.continuesInBackground
                 ? "Translation stops if you close this screen. You can lock your phone or switch apps instead. Finished passages are kept."
                 : "Translation stops if you close this screen. Finished passages are kept.")
        }
        .background {
            EscapeKeyHandler(action: close)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            if let translationJob {
                NarrationTranslationTaskHost(
                    job: translationJob,
                    updateStage: { if lifetime?.id == translationJob.id { stage = $0 } },
                    complete: { finish($0, lifetime: translationJob.lifetime) },
                    stop: { cancelPreparation(matching: translationJob.id) }
                )
                .id(translationJob.id)
            }
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
            cancelPreparation()
            availabilityTask?.cancel()
            availabilityRequestID = nil
            loadingLanguages = false
            updateIdleTimer()
            EngagementService.shared.unregisterNarrationPresentation(owner: presentationOwner)
        }
        .onChange(of: scenePhase) { _, phase in
            // With system background time, locking the phone or switching apps keeps preparing.
            if phase == .background, !narrations.continuesInBackground { cancelPreparation() }
            if phase == .active {
                refreshCachedAudio()
                originalAudioURL = downloads.localFileURL(for: discourseID)
                if readingDocument == nil, languages.isEmpty, !loadingLanguages { refreshLanguages() }
            }
            updateIdleTimer()
        }
        .onChange(of: narrations.documents) { _, _ in refreshCachedAudio() }
        .onChange(of: narrations.preparationOwner) { _, owner in
            guard let preparationOwner, owner != preparationOwner, lifetime != nil else { return }
            // Successful preparation releases its lease before returning the document.
            // Other lease loss must retire a session even if a native call has not returned.
            if translationJob == nil || narrations.progress < 1 { cancelPreparation() }
        }
        .onChange(of: serviceBusy) { _, busy in
            if !busy, readingDocument == nil, languages.isEmpty, !loadingLanguages { refreshLanguages() }
        }
        .onChange(of: downloads.downloadedIDs) { _, _ in
            originalAudioURL = downloads.localFileURL(for: discourseID)
        }
        .onChange(of: player.isPlaying) { _, _ in updateIdleTimer() }
        .onReceive(NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)) { _ in
            if readingDocument == nil, !isBusy { refreshLanguages() }
        }
        .onChange(of: player.currentNarration) { _, document in
            if let document, document.discourseID == discourseID { readingDocument = document }
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
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry?.discourse.displayTitle ?? "Saved Discourse").font(.headline)
                    if let sourceLanguage {
                        Text("From the \(NarrationLanguageSupport.displayName(for: sourceLanguage)) transcript")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text("A synthetic voice reads the translation, not Osho. Wording and pronunciation may be inaccurate.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("narration.explanation")
                }
                .padding(.vertical, 4)
            }
            if lifetime != nil {
                preparationProgress
            } else if serviceBusy {
                Section {
                    Label("Another narration is being prepared. Please wait.", systemImage: "hourglass")
                        .font(.footnote)
                        .accessibilityIdentifier("narration.busy")
                }
            }
            if let errorMessage {
                Section {
                    Label("Preparation Failed", systemImage: "exclamationmark.triangle").font(.headline)
                    Text(errorMessage).font(.footnote).textSelection(.enabled)
                        .accessibilityIdentifier("narration.preparationError")
                    if let retrySelection {
                        selectionLabel(retrySelection)
                        Button("Try Again") { beginPreparation(retrySelection) }
                            .disabled(isBusy).accessibilityIdentifier("narration.retry")
                    }
                }
            } else if let statusMessage {
                Section {
                    Text(statusMessage).font(.footnote)
                    if let retrySelection {
                        selectionLabel(retrySelection)
                        Button("Resume preparation", systemImage: "play.fill") { beginPreparation(retrySelection) }
                            .disabled(isBusy).accessibilityIdentifier("narration.resumePreparation")
                    }
                }
            }
            if let featuredVariant {
                Section("Saved narration") { savedNarrationRow(featuredVariant) }
            }
            if !cacheLoaded {
                Section { ProgressView("Loading saved narrations…") }
            } else if lifetime == nil, !serviceBusy {
                if sourceLanguage == nil {
                    Section {
                        Text("This discourse is no longer in the catalog. Its saved narration cannot be opened in the player.")
                            .accessibilityIdentifier("narration.missingDiscourse")
                    }
                } else if transcripts.availability(for: discourseID) == .unavailable {
                    Section {
                        Label("No transcript yet", systemImage: "doc.plaintext").font(.headline)
                            .accessibilityIdentifier("narration.noTranscript")
                        Text("This discourse needs a source transcript before it can be translated.").font(.footnote)
                    }
                } else {
                    languageControls
                }
            }
            if variants.contains(where: { $0.id != featuredVariantID }) {
                Section {
                    ForEach(variants.filter { $0.id != featuredVariantID }) { savedNarrationRow($0) }
                } header: {
                    Text("Saved on this device")
                } footer: {
                    Text("Saved audio plays offline. Resume keeps the same language and voice.")
                }
            }
            if let cacheError {
                Section {
                    Text(cacheError).font(.footnote).foregroundStyle(.orange)
                    Button("Reload saved narrations") { cacheReloadGeneration += 1 }.disabled(isBusy)
                }
            }
            if player.currentNarration?.discourseID == discourseID { originalAudioSection }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.bottom, 24, for: .scrollContent)
        .accessibilityIdentifier("narration.preparation")
    }

    private func savedNarrationRow(_ document: NarrationDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SavedNarrationLabel(document: document, isPlayable: playableIDs.contains(document.id))
            ViewThatFits(in: .horizontal) {
                HStack { savedNarrationActions(document) }
                VStack(alignment: .leading) { savedNarrationActions(document) }
            }
            .buttonStyle(.borderless)
            .disabled(!deletingIDs.isEmpty)
            if document.isComplete, player.narrationPlaybackFailure != nil {
                Button("Rebuild This Narration", systemImage: "arrow.triangle.2.circlepath") {
                    delete(document, prepareAgain: true)
                }
                .buttonStyle(.borderless)
                .disabled(isBusy || entry == nil)
                .accessibilityIdentifier("narration.rebuild.\(document.id)")
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func savedNarrationActions(_ document: NarrationDocument) -> some View {
        if playableIDs.contains(document.id) {
            Button(player.currentNarration == document && player.isPlaying ? "Read Along" : "Play", systemImage: "play.fill") {
                play(document)
            }
            .frame(minHeight: 44)
            .disabled(entry == nil)
            .accessibilityIdentifier("narration.play.\(document.id)")
        } else {
            if !document.isComplete, narrations.preparingDocumentID != document.id,
               narrations.playablePrefix(of: document.id) != nil {
                Button(listenLabel(for: document), systemImage: "headphones") { play(document) }
                    .frame(minHeight: 44)
                    .disabled(entry == nil)
                    .accessibilityIdentifier("narration.listen.\(document.id)")
            }
            Button(document.isComplete ? "Rebuild" : "Resume", systemImage: "arrow.clockwise") {
                featuredVariantID = document.id
                beginPreparation(document.selection)
            }
            .frame(minHeight: 44)
            .disabled(isBusy || entry == nil || transcripts.availability(for: discourseID) == .unavailable)
            .accessibilityIdentifier("narration.resume.\(document.id)")
        }
        Button("Delete", systemImage: "trash", role: .destructive) { delete(document) }
            .frame(minHeight: 44)
            .disabled(isBusy)
            .accessibilityIdentifier("narration.delete.\(document.id)")
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
                    Text("Check the available languages and voices to prepare a narration.").font(.footnote)
                }
            } else {
                Picker("Language", selection: Binding(
                    get: { selectedLanguageID },
                    set: { id in
                        selectedLanguageID = id
                        selectedVoiceID = languages.first { $0.id == id }?.voices.first?.id ?? ""
                    }
                )) {
                    Text("Choose a language").tag("")
                    ForEach(languages) { Text($0.displayName).tag($0.id) }
                }
                .accessibilityIdentifier("narration.targetLanguage")
                .disabled(isBusy)
                if let language = selectedLanguage {
                    if language.voices.isEmpty {
                        Text("No voice for \(language.displayName) is available. Add a system voice in accessibility settings, then check again.")
                            .font(.footnote).accessibilityIdentifier("narration.noVoice")
                    } else {
                        Picker("Voice", selection: $selectedVoiceID) {
                            Text("Choose a voice").tag("")
                            ForEach(language.voices) { voice in
                                Text("\(voice.narrationDisplayName) · \(NarrationLanguageSupport.displayName(for: voice.language))")
                                    .tag(voice.id)
                            }
                        }
                        .accessibilityIdentifier("narration.voice")
                        .disabled(isBusy)
                    }
                    Text(language.support.status == .installed
                         ? "The translation language is ready on this device."
                         : "Apple may ask to download the translation language.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button("Prepare narration", systemImage: "waveform") {
                    if let selection { beginPreparation(selection) }
                }
                .disabled(selection == nil || isBusy)
                .accessibilityIdentifier("narration.prepare")
                if let availabilityError { Text(availabilityError).font(.footnote).foregroundStyle(.orange) }
            }
            Button("Check again", systemImage: "arrow.clockwise", action: refreshLanguages)
                .disabled(loadingLanguages || isBusy)
                .accessibilityIdentifier("narration.refreshLanguages")
        } header: {
            Text("Language and voice")
        } footer: {
            Text(Self.preparationFooter)
                .accessibilityIdentifier("narration.preparationFooter")
        }
    }

    private static var preparationFooter: String {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) {
            return "You can listen while it translates. Locking your phone or switching apps keeps it going, with progress on the Lock Screen. Closing this screen pauses it."
        }
        #endif
        return "You can listen while it translates. Leaving this screen or the app pauses it and keeps finished passages."
    }

    private var preparationProgress: some View {
        Section("Preparing") {
            if let retrySelection { selectionLabel(retrySelection) }
            if stage == .creatingAudio, narrations.preparingDiscourseID == discourseID {
                ProgressView(value: narrations.progress.isFinite ? min(1, max(0, narrations.progress)) : 0)
                Text(narrations.statusMessage).font(.subheadline)
                if narrations.totalPassages > 0 {
                    HStack {
                        Text(NarrationTimeFormatting.passages(narrations.completedPassages, of: narrations.totalPassages))
                        Spacer()
                        Text(narrations.estimatedSecondsRemaining.map(NarrationTimeFormatting.remaining) ?? "Estimating time…")
                    }
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("narration.estimate")
                }
                if let preparing = preparingDocument, narrations.playablePrefix(of: preparing.id) != nil {
                    Button(listenLabel(for: preparing), systemImage: "headphones") { play(preparing) }
                        .frame(minHeight: 44)
                        .disabled(entry == nil)
                        .accessibilityIdentifier("narration.listenWhilePreparing")
                }
            } else {
                ProgressView(stage.label)
            }
            Button("Pause and save", systemImage: "pause.circle") { cancelPreparation() }
                .accessibilityIdentifier("narration.cancel")
        }
        .accessibilityIdentifier("narration.progress")
    }

    private var preparingDocument: NarrationDocument? {
        guard let id = narrations.preparingDocumentID else { return nil }
        return variants.first { $0.id == id }
    }

    private func listenLabel(for document: NarrationDocument) -> String {
        player.currentNarration?.id == document.id ? "Read Along" : "Listen to Finished Part"
    }

    private func selectionLabel(_ selection: NarrationSelection) -> some View {
        Text("\(NarrationLanguageSupport.displayName(for: selection.targetLanguage)) · \(selection.voice.narrationDisplayName)")
            .font(.subheadline).foregroundStyle(.secondary)
    }

    private var originalAudioSection: some View {
        Section {
            Button("Return to Original", systemImage: "arrow.uturn.backward", action: returnToOriginal)
                .disabled(originalAudioURL == nil || entry == nil || isBusy)
                .accessibilityIdentifier("narration.returnToOriginal")
            if originalAudioURL == nil {
                Text("Download the original audio from the series page to return to Osho's recording.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func loadCachedNarrations() async {
        let firstLoad = !cacheLoaded
        await narrations.load()
        guard !Task.isCancelled else { return }
        refreshCachedAudio()
        cacheLoaded = true
        cacheError = narrations.errorMessage
        if firstLoad {
            if let featuredVariant, playableIDs.contains(featuredVariant.id) {
                readingDocument = featuredVariant
            } else if featuredVariantID == nil, let document = player.currentNarration,
                      document.discourseID == discourseID, NarrationCachePresentation.audioURL(for: document) != nil {
                readingDocument = document
            }
        }
        if readingDocument == nil { refreshLanguages() }
    }

    private func refreshCachedAudio() { playableIDs = NarrationCachePresentation.playableIDs(in: variants) }

    private func refreshLanguages() {
        guard isVisible, scenePhase == .active, let sourceLanguage, !isBusy,
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
                let choice = NarrationSelectionPresentation.choice(
                    sourceLanguage: sourceLanguage, languages: options,
                    languageID: selectedLanguageID, voiceID: selectedVoiceID,
                    saved: narrations.documents, preferredDocumentID: featuredVariantID
                )
                selectedLanguageID = choice.languageID
                selectedVoiceID = choice.voiceID
            } catch {
                guard !Task.isCancelled, availabilityRequestID == requestID else { return }
                availabilityError = "Couldn't check translation languages. Please try again."
                Self.log.error("Availability outcome=failed")
            }
            if availabilityRequestID == requestID { loadingLanguages = false }
        }
    }

    private func beginPreparation(_ requested: NarrationSelection) {
        guard !isBusy, isVisible, scenePhase == .active else { return }
        // The lease covers preflight and Apple's consent, not just audio rendering.
        let owner = UUID()
        guard narrations.reservePreparation(owner: owner) else { return }
        preparationOwner = owner
        availabilityTask?.cancel()
        availabilityRequestID = nil
        loadingLanguages = false
        let attempt = NarrationTranslationLifetime()
        lifetime = attempt
        retrySelection = requested
        errorMessage = nil
        cacheError = nil
        statusMessage = nil
        stage = .checkingSupport
        updateIdleTimer()
        Self.log.info("Preparation outcome=started")
        startupTask = Task {
            do {
                try checkPreflight(attempt, owner: owner)
                guard let sourceLanguage,
                      NarrationLanguageSupport.languageAndScript(for: sourceLanguage)
                        == NarrationLanguageSupport.languageAndScript(for: requested.sourceLanguage) else {
                    throw NarrationPreparationError.invalidSelection
                }
                guard let support = try await NarrationLanguageSupport.support(from: sourceLanguage, to: requested.targetLanguage) else {
                    throw NarrationTranslationError.unsupportedPair
                }
                try checkPreflight(attempt, owner: owner)
                stage = .fetchingTranscript
                let transcript = try await transcripts.transcript(for: discourseID)
                try checkPreflight(attempt, owner: owner)
                let configuration = try NarrationLanguageSupport.configuration(
                    source: sourceLanguage, target: requested.targetLanguage, strategy: support.strategy
                )
                stage = .preparingLanguages
                translationJob = NarrationTranslationJob(
                    lifetime: attempt, owner: owner, transcript: transcript, selection: requested, configuration: configuration
                )
                Self.log.info("Preparation strategy=\(support.strategy.rawValue, privacy: .public)")
            } catch {
                finish(.failure(error), lifetime: attempt)
            }
        }
    }

    private func checkPreflight(_ attempt: NarrationTranslationLifetime, owner: UUID) throws {
        try attempt.check()
        guard lifetime?.id == attempt.id, narrations.preparationOwner == owner else { throw CancellationError() }
    }

    private func finish(_ result: Result<NarrationDocument, Error>, lifetime attempt: NarrationTranslationLifetime) {
        guard lifetime?.id == attempt.id else { return }
        attempt.invalidate()
        switch result {
        case .success(let document):
            refreshCachedAudio()
            featuredVariantID = document.id
            statusMessage = "Narration is ready. Tap Play to listen."
            retrySelection = nil
            Self.log.info("Preparation outcome=ready")
        case .failure(let error):
            if error is CancellationError {
                statusMessage = "Preparation paused. Completed text and audio are saved. Resume when you're ready."
                Self.log.info("Preparation outcome=cancelled")
            } else {
                errorMessage = preparationFailureMessage(error)
                Self.log.error("Preparation outcome=failed stage=\(stage.rawValue, privacy: .public)")
            }
        }
        if let owner = preparationOwner {
            narrations.cancel(owner: owner)
            narrations.releasePreparation(owner: owner)
        }
        preparationOwner = nil
        translationJob = nil
        lifetime = nil
        startupTask = nil
        updateIdleTimer()
    }

    private func preparationFailureMessage(_ error: Error) -> String {
        if let error = error as? NarrationTranslationError { return error.localizedDescription }
        if let error = error as? NarrationPreparationError { return error.localizedDescription }
        if let error = error as? NativeNarrationSpeechError { return error.localizedDescription }
        if stage == .fetchingTranscript {
            if let error = error as? TranscriptFetcher.FetchError { return error.localizedDescription }
            return "Couldn't load the source transcript. Check your connection and try again."
        }
        if stage == .creatingAudio {
            let detail = narrations.errorMessage
                ?? "Check free storage and the selected system voice, then try again. Saved segments are kept."
            return "Couldn't finish creating the narration audio. \(detail)"
        }
        return "Couldn't prepare this narration. Check the language downloads and try again."
    }

    private func cancelPreparation(matching id: UUID? = nil) {
        guard let attempt = lifetime, id == nil || id == attempt.id else { return }
        attempt.invalidate()
        if let owner = preparationOwner {
            narrations.cancel(owner: owner)
            narrations.releasePreparation(owner: owner)
        }
        preparationOwner = nil
        startupTask?.cancel()
        startupTask = nil
        translationJob = nil
        lifetime = nil
        errorMessage = nil
        statusMessage = "Preparation paused. Completed text and audio are saved. Resume when you're ready."
        updateIdleTimer()
        Self.log.info("Preparation outcome=cancelled")
    }

    private func updateIdleTimer() {
        ScreenAwakeService.shared.setAwake(NarrationPlaybackPresentation.keepsScreenAwake(
            isVisible: isVisible, scenePhase: scenePhase, isPreparing: lifetime != nil,
            reading: readingDocument, current: player.currentNarration, isPlaying: player.isPlaying
        ), owner: presentationOwner)
    }

    private func close() {
        if lifetime != nil {
            confirmingClose = true
            return
        }
        dismiss()
    }

    private func pauseAndClose() {
        cancelPreparation()
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
            errorMessage = "The saved audio is missing or unreadable. Resume the narration to rebuild it."
            retrySelection = document.selection
            return
        }
        switch NarrationPlaybackPresentation.action(
            for: document, current: player.currentNarration, isPlaying: player.isPlaying,
            hasFailure: player.narrationPlaybackFailure != nil
        ) {
        case .load: player.playNarration(document, url: url)
        case .resume: player.togglePlayPause()
        case .readAlong: break
        }
        readingDocument = document
    }

    private func playFinishedPassages(of document: NarrationDocument) {
        if player.currentNarration?.id == document.id, player.narrationPlaybackFailure == nil {
            // At the end of the finished passages, resuming continues with any newer ones.
            if !player.isPlaying { player.togglePlayPause() }
        } else {
            NarrationPreviewPlayback.shared.play(documentID: document.id, player: player)
        }
        readingDocument = narrations.documents.first { $0.id == document.id } ?? document
    }

    private func delete(_ document: NarrationDocument, prepareAgain: Bool = false) {
        guard !isBusy else { return }
        if player.currentNarration?.id == document.id { player.stop() }
        deletingIDs.insert(document.id)
        Task {
            defer { deletingIDs.remove(document.id) }
            do {
                try await narrations.remove(document.id)
                if readingDocument?.id == document.id { readingDocument = nil }
                if featuredVariantID == document.id { featuredVariantID = nil }
                if retrySelection == document.selection {
                    retrySelection = nil
                    statusMessage = nil
                    errorMessage = nil
                }
                if prepareAgain {
                    deletingIDs.remove(document.id)
                    beginPreparation(document.selection)
                }
            } catch {
                errorMessage = "Couldn't delete the saved narration. Please try again."
                retrySelection = nil
                Self.log.error("Cache deletion outcome=failed")
            }
        }
    }

    private func returnToOriginal() {
        guard !isBusy, let entry else { return }
        guard let url = downloads.localFileURL(for: discourseID) else {
            originalAudioURL = nil
            return
        }
        player.returnToOriginal(localURL: url, id: discourseID, title: entry.discourse.displayTitle, series: entry.series.name)
        dismiss()
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
            Button("Resume or Rebuild Narration", systemImage: "arrow.clockwise", action: recover)
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

private enum NarrationPreparationStage: String {
    case checkingSupport, fetchingTranscript, preparingLanguages, creatingAudio
    var label: String {
        switch self {
        case .checkingSupport: "Checking the language pair…"
        case .fetchingTranscript: "Loading the source transcript…"
        case .preparingLanguages: "Preparing translation languages…"
        case .creatingAudio: "Translating and creating audio…"
        }
    }
}

@available(macCatalyst 26.0, *)
private struct NarrationTranslationJob: Identifiable {
    let lifetime: NarrationTranslationLifetime
    let owner: UUID
    let transcript: Transcript
    let selection: NarrationSelection
    let configuration: TranslationSession.Configuration
    var id: UUID { lifetime.id }
}

// Each attempt owns a fresh host, so no session survives its language-download consent presentation.
@available(macCatalyst 26.0, *)
private struct NarrationTranslationTaskHost: View {
    let job: NarrationTranslationJob
    let updateStage: @MainActor (NarrationPreparationStage) -> Void
    let complete: @MainActor (Result<NarrationDocument, Error>) -> Void
    let stop: @MainActor () -> Void
    @State private var configuration: TranslationSession.Configuration?
    @State private var started = false

    init(
        job: NarrationTranslationJob,
        updateStage: @escaping @MainActor (NarrationPreparationStage) -> Void,
        complete: @escaping @MainActor (Result<NarrationDocument, Error>) -> Void,
        stop: @escaping @MainActor () -> Void
    ) {
        self.job = job
        self.updateStage = updateStage
        self.complete = complete
        self.stop = stop
        _configuration = State(initialValue: job.configuration)
    }

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityHidden(true)
            .translationTask(configuration) { @MainActor session in
                guard !started else { return }
                started = true
                do {
                    try job.lifetime.check()
                    let service = NarrationService.shared
                    guard service.preparationOwner == job.owner else { throw CancellationError() }
                    updateStage(.creatingAudio)
                    var languagesPrepared = false
                    let document = try await service.prepare(
                        transcript: job.transcript, selection: job.selection,
                        translate: { texts in
                            // Complete cached batches need neither translation assets nor download consent.
                            if !languagesPrepared {
                                updateStage(.preparingLanguages)
                                try await AppleNarrationTranslator.prepare(using: session, lifetime: job.lifetime)
                                try job.lifetime.check()
                                languagesPrepared = true
                                updateStage(.creatingAudio)
                            }
                            return try await AppleNarrationTranslator.translate(
                                texts, using: session,
                                sourceLanguage: job.selection.sourceLanguage, targetLanguage: job.selection.targetLanguage,
                                lifetime: job.lifetime
                            )
                        },
                        renderer: NativeNarrationSpeechRenderer(), owner: job.owner,
                        onFailure: { complete(.failure($0)) }
                    )
                    try job.lifetime.check()
                    complete(.success(document))
                } catch {
                    complete(.failure(error))
                }
            }
            .onDisappear {
                stop()
                job.lifetime.invalidate()
                configuration?.invalidate()
                configuration = nil
            }
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
            Text("\(document.selection.voice.narrationDisplayName) · Synthetic voice")
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
    let returnToOriginal: @MainActor () -> Void
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable private var settings = UserSettings.shared
    @State private var following = NarrationPlaybackPresentation.Following()
    @State private var audioAvailable = true
    private let narrations = NarrationService.shared
    private let preview = NarrationPreviewPlayback.shared

    /// New passages keep arriving while a rendition is prepared; the reader follows the saved copy.
    private var live: NarrationDocument { narrations.documents.first { $0.id == document.id } ?? document }
    private var isCurrent: Bool { player.currentNarration?.id == document.id }
    private var isPreparingThis: Bool { narrations.preparingDocumentID == document.id }
    private var catalogEntryAvailable: Bool { Catalog.discourseLookup[document.discourseID] != nil }
    private var highlightedIndex: Int? { isCurrent ? live.segmentIndex(at: player.currentTime) : nil }
    private var accent: Color { settings.effectiveAccentTheme.color }
    private var fontSize: CGFloat { CGFloat(settings.transcriptFontSize) }
    private var isBusy: Bool { narrations.isPreparing || narrations.preparationOwner != nil }
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
                                    guard isCurrent else { return }
                                    seek(toPassage: segment.index)
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
                                .disabled(!isCurrent)
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
                Text("\(NarrationTimeFormatting.passages(live.segments.count, of: live.expectedSegmentCount)) ready. Resume preparation to hear the rest.")
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

    private func seek(toPassage index: Int) {
        let start = live.startTime(forSegmentAt: index)
        if let current = player.currentNarration, !current.isComplete, index >= current.segments.count {
            // A newer passage is outside the timeline that is playing; rebuild it to include that passage.
            preview.play(documentID: document.id, player: player, resumeAt: start)
        } else {
            player.seek(to: start)
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
                    .accessibilityLabel(live.isComplete ? "Narration progress" : "Progress through finished passages")
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
                    .accessibilityLabel(player.isPlaying ? "Pause narration" : "Play narration")
                    .accessibilityIdentifier("narration.togglePlayback")
                    Button { player.skipForward() } label: {
                        Image(systemName: "goforward.30").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Skip forward 30 seconds")
                } else {
                    Button(live.isComplete ? "Play Narration" : "Play Finished Part", systemImage: "play.fill", action: play)
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
            Button("Return to Original", systemImage: "arrow.uturn.backward", action: returnToOriginal)
                .frame(minHeight: 44)
                .disabled(!canReturnToOriginal || isBusy)
                .accessibilityIdentifier("narration.returnToOriginal")
            if !canReturnToOriginal {
                Text("Download the original audio from the series page to return to Osho's recording.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
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

struct TranslatedNarrationLibraryView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(DownloadService.self) private var downloads
    @Environment(\.horizontalSizeClass) private var sizeClass
    private let narrations = NarrationService.shared
    @State private var loaded = false
    @State private var playableIDs = Set<String>()
    @State private var selectedDocument: NarrationDocument?
    @State private var presentationOwner = UUID()

    var body: some View {
        List {
            if !loaded {
                ProgressView("Loading saved narrations…").accessibilityIdentifier("narration.library.loading")
            } else if narrations.documents.isEmpty {
                ContentUnavailableView(
                    "No Translated Narrations", systemImage: "globe",
                    description: Text("Open a discourse in the player and tap Translate to prepare a narration.")
                )
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("narration.library.empty")
            }
            ForEach(narrations.documents.sorted { $0.updatedAt > $1.updatedAt }) { document in
                Button { selectedDocument = document } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Catalog.discourseLookup[document.discourseID]?.discourse.displayTitle ?? "Saved Discourse")
                            .font(.subheadline).foregroundStyle(.primary)
                        SavedNarrationLabel(document: document, isPlayable: playableIDs.contains(document.id))
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens playback, resume and delete options")
                .accessibilityIdentifier("narration.library.\(document.id)")
            }
            if let error = narrations.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.orange)
                Button("Try Again") { Task { await load() } }
            }
        }
        .listStyle(.insetGrouped)
        .readableScrollColumn(sizeClass)
        .navigationTitle("Translated Narrations")
        .accessibilityIdentifier("narration.library")
        .reservesMiniPlayerSpace()
        .task { await load() }
        .onAppear { EngagementService.shared.registerNarrationPresentation(owner: presentationOwner) }
        .onDisappear { EngagementService.shared.unregisterNarrationPresentation(owner: presentationOwner) }
        .onChange(of: narrations.documents) { _, documents in
            playableIDs = NarrationCachePresentation.playableIDs(in: documents)
        }
        .sheet(item: $selectedDocument) { document in
            if #available(macCatalyst 26.0, *) {
                TranslatedNarrationView(discourseID: document.discourseID, selectedDocumentID: document.id)
                    .environment(player)
                    .environment(downloads)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private func load() async {
        await narrations.load()
        guard !Task.isCancelled else { return }
        playableIDs = NarrationCachePresentation.playableIDs(in: narrations.documents)
        loaded = true
    }
}
#endif
