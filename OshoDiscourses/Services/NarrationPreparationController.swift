#if TRANSLATED_NARRATION
import Foundation
import Observation
import SwiftUI
@preconcurrency import Translation
import os

enum NarrationPreparationStage: String {
    case checkingSupport, fetchingTranscript, preparingLanguages, creatingAudio
    var label: String {
        switch self {
        case .checkingSupport: "Checking the language…"
        case .fetchingTranscript: "Loading the transcript…"
        case .preparingLanguages: "Preparing translation languages…"
        case .creatingAudio: "Preparing your audio…"
        }
    }
}

@available(macCatalyst 26.0, *)
struct NarrationTranslationJob: Identifiable {
    let lifetime: NarrationTranslationLifetime
    let owner: UUID
    let hostID: UUID
    let transcript: Transcript
    let selection: NarrationSelection
    let configuration: TranslationSession.Configuration
    var id: UUID { lifetime.id }
}

enum NarrationStopReason: String, Codable, Sendable {
    case paused, leftApp, backgroundEnded, appClosed, windowClosed, interrupted, failed

    /// Only the listener's own pause waits for a tap; iOS stops continue when the app is next open.
    var continuesAutomatically: Bool { self != .paused }

    var explanation: String {
        switch self {
        case .paused: "Paused"
        case .leftApp: "Paused when you left the app"
        case .backgroundEnded: "Paused by iOS"
        case .appClosed: "Paused when iOS closed the app"
        case .windowClosed: "Paused when its window closed"
        case .interrupted: "Paused"
        case .failed: "Stopped after an error"
        }
    }
}

/// The translation that was running or stopped last, kept across launches so it can continue where it left off.
struct NarrationUnfinishedRun: Codable, Equatable, Sendable {
    let discourseID: String
    let selection: NarrationSelection
    var lastProgressAt: Date
    var stoppedAt: Date?
    var reason: NarrationStopReason?
    var automaticAttempts = 0
    var passagesAtStart = 0

    func matches(discourseID: String, selection: NarrationSelection) -> Bool {
        self.discourseID == discourseID && TranslatedListening.isSameVersion(self.selection, selection)
    }
}

/// The app window owns translation, not the listening sheet. Closing a sheet never retires its session.
@available(macCatalyst 26.0, *)
@Observable @MainActor
final class NarrationPreparationController {
    static let shared = NarrationPreparationController(defaults: .standard, journal: .shared)
    private static let log = Logger(subsystem: "com.agraabhi.oshodiscourses", category: "NarrationTranslation")
    static let unfinishedRunKey = "narration.unfinishedRun"
    /// Automatic continues in a row that saved no new passage; past this only the listener can retry.
    static let automaticAttemptLimit = 3

    private(set) var job: NarrationTranslationJob?
    private(set) var discourseID: String?
    private(set) var selection: NarrationSelection?
    private(set) var stage = NarrationPreparationStage.checkingSupport
    private(set) var errorMessage: String?
    private(set) var statusMessage: String?
    private(set) var lifetime: NarrationTranslationLifetime?
    private(set) var hostID: UUID?
    private(set) var unfinished: NarrationUnfinishedRun?
    @ObservationIgnored private var startup: Task<Void, Never>?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var owner: UUID?
    @ObservationIgnored private var autoplay: (player: AudioPlayerService, generation: UInt64, intent: UInt64)?
    @ObservationIgnored private let narrations: NarrationService
    @ObservationIgnored private let findSupport: @MainActor (String, String) async throws -> NarrationTranslationSupport?
    @ObservationIgnored private let fetchTranscript: @MainActor (String) async throws -> Transcript
    @ObservationIgnored private let isPlayingAudio: @MainActor () -> Bool
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let journal: NarrationJournal?
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let makeRenderer: @MainActor (NarrationSelection) -> any NarrationSpeechRendering
    @ObservationIgnored private var joining: (owner: UUID, documentID: String, task: Task<Void, Never>)?
    /// Joining is tried once per launch, so a lasting failure can't repeat on every return to the app.
    @ObservationIgnored private var joinAttempts: Set<String> = []

    init(
        narrations: NarrationService = .shared,
        findSupport: @escaping @MainActor (String, String) async throws -> NarrationTranslationSupport? = {
            try await NarrationLanguageSupport.support(from: $0, to: $1)
        },
        fetchTranscript: @escaping @MainActor (String) async throws -> Transcript = {
            try await TranscriptService.shared.transcript(for: $0)
        },
        isPlayingAudio: @escaping @MainActor () -> Bool = { AppRuntime.shared.audioPlayer.isPlaying },
        defaults: UserDefaults? = nil,
        journal: NarrationJournal? = nil,
        now: @escaping @MainActor () -> Date = Date.init,
        makeRenderer: @escaping @MainActor (NarrationSelection) -> any NarrationSpeechRendering = {
            NativeNarrationSpeechRenderer(rateScale: $0.pace.voiceRateScale)
        }
    ) {
        self.narrations = narrations
        self.makeRenderer = makeRenderer
        self.findSupport = findSupport
        self.fetchTranscript = fetchTranscript
        self.isPlayingAudio = isPlayingAudio
        self.defaults = defaults
        self.journal = journal
        self.now = now
        if let data = defaults?.data(forKey: Self.unfinishedRunKey),
           var saved = try? JSONDecoder().decode(NarrationUnfinishedRun.self, from: data) {
            // Still marked running at launch: the process ended without any stop being recorded.
            if saved.reason == nil {
                saved.reason = .appClosed
                saved.stoppedAt = saved.lastProgressAt
                journal?.record("launch found an unfinished run; the app ended while translating")
            }
            unfinished = saved
            persist()
        }
    }

    var isRunning: Bool { lifetime != nil }

    func start(
        discourseID: String, selection: NarrationSelection, hostID: UUID, player: AudioPlayerService, listen: Bool,
        automatic: Bool = false
    ) {
        guard !isRunning else { return }
        stopJoining()
        let service = narrations
        let owner = UUID()
        guard service.reservePreparation(owner: owner) else { return }
        let attempt = NarrationTranslationLifetime()
        self.owner = owner
        self.hostID = hostID
        self.discourseID = discourseID
        self.selection = selection
        lifetime = attempt
        errorMessage = nil
        statusMessage = nil
        stage = .checkingSupport
        autoplay = listen ? (player, player.playbackGeneration, player.playbackIntentGeneration) : nil
        let passages = service.documents.first {
            $0.discourseID == discourseID && TranslatedListening.isSameVersion($0.selection, selection)
        }?.segments.count ?? 0
        var attempts = 0
        if automatic, let previous = unfinished, previous.matches(discourseID: discourseID, selection: selection) {
            attempts = passages > previous.passagesAtStart ? 1 : previous.automaticAttempts + 1
        }
        unfinished = NarrationUnfinishedRun(
            discourseID: discourseID, selection: selection, lastProgressAt: now(),
            automaticAttempts: attempts, passagesAtStart: passages
        )
        persist()
        journal?.record("start discourse=\(discourseID) target=\(selection.targetLanguage) voice=\(selection.voice.id) pace=\(selection.pace.rawValue) passages=\(passages) automatic=\(automatic)")
        Self.log.info("Preparation outcome=started automatic=\(automatic, privacy: .public)")
        startup = Task {
            do {
                try attempt.check()
                guard let support = try await findSupport(selection.sourceLanguage, selection.targetLanguage) else {
                    throw NarrationTranslationError.unsupportedPair
                }
                try attempt.check()
                stage = .fetchingTranscript
                let transcript = try await fetchTranscript(discourseID)
                try attempt.check()
                let configuration = try NarrationLanguageSupport.configuration(
                    source: selection.sourceLanguage, target: selection.targetLanguage, strategy: support.strategy
                )
                stage = .preparingLanguages
                job = NarrationTranslationJob(lifetime: attempt, owner: owner, hostID: hostID,
                                               transcript: transcript, selection: selection, configuration: configuration)
            } catch {
                finish(.failure(error), attempt: attempt)
            }
        }
    }

    func updateStage(_ value: NarrationPreparationStage, attempt: NarrationTranslationLifetime) {
        guard lifetime?.id == attempt.id else { return }
        stage = value
    }

    /// Only language consent uses the view-provided session. Installed sessions have no UI lifetime.
    func languagesReady(for job: NarrationTranslationJob, foregroundSession: TranslationSession) async {
        guard lifetime?.id == job.id, work == nil else { return }
        if #available(iOS 26.0, macCatalyst 26.0, *) {
            work = Task {
                let source = Locale.Language(identifier: job.selection.sourceLanguage)
                let target = Locale.Language(identifier: job.selection.targetLanguage)
                let session: TranslationSession
                if #available(iOS 26.4, macCatalyst 26.4, *) {
                    session = TranslationSession(installedSource: source, target: target,
                                                 preferredStrategy: job.configuration.preferredStrategy)
                } else {
                    session = TranslationSession(installedSource: source, target: target)
                }
                await render(job, using: session)
            }
        } else {
            await render(job, using: foregroundSession)
        }
    }

    private func render(_ job: NarrationTranslationJob, using session: TranslationSession) async {
        do {
            try job.lifetime.check()
            updateStage(.creatingAudio, attempt: job.lifetime)
            let document = try await narrations.prepare(
                transcript: job.transcript, selection: job.selection,
                translate: { texts in
                    try await AppleNarrationTranslator.translate(
                        texts, using: session, sourceLanguage: job.selection.sourceLanguage,
                        targetLanguage: job.selection.targetLanguage, lifetime: job.lifetime
                    )
                }, renderer: NativeNarrationSpeechRenderer(rateScale: job.selection.pace.voiceRateScale),
                owner: job.owner, onFailure: { self.finish(.failure($0), attempt: job.lifetime) },
                onProgress: { _ in
                    self.recordProgress(attempt: job.lifetime)
                    self.playWhenReady()
                }
            )
            try job.lifetime.check()
            finish(.success(document), attempt: job.lifetime)
        } catch {
            finish(.failure(error), attempt: job.lifetime)
        }
    }

    func finish(_ result: Result<NarrationDocument, Error>, attempt: NarrationTranslationLifetime) {
        guard lifetime?.id == attempt.id else { return }
        switch result {
        case .success:
            playWhenReady()
            statusMessage = "Ready to listen."
            unfinished = nil
            persist()
            journal?.record("finished")
            Self.log.info("Preparation outcome=ready")
        case .failure(let error):
            if error is CancellationError {
                statusMessage = "Preparation paused. Your finished audio is saved."
                markStopped(Self.reason(for: narrations.backgroundStatus))
                Self.log.info("Preparation outcome=paused")
            } else {
                errorMessage = failureMessage(error)
                markStopped(.failed, detail: "stage=\(stage.rawValue) error=\(NarrationJournal.describe(error))")
                Self.log.error("Preparation outcome=failed stage=\(self.stage.rawValue, privacy: .public)")
            }
        }
        retire()
    }

    func pause(message: String = "Preparation paused. Your finished audio is saved.", reason: NarrationStopReason = .paused) {
        guard isRunning else { return }
        statusMessage = message
        errorMessage = nil
        markStopped(reason)
        retire()
        Self.log.info("Preparation outcome=paused reason=\(reason.rawValue, privacy: .public)")
    }

    func hostDisappeared(_ id: UUID) {
        guard hostID == id else { return }
        pause(message: "Preparation paused because its window closed. Your finished audio is saved.", reason: .windowClosed)
    }

    func sceneChanged(_ phase: ScenePhase, hostID: UUID) {
        guard self.hostID == hostID, isRunning, phase == .background else { return }
        // Playing audio keeps the app running, so translation can go on without a background task.
        let playing = isPlayingAudio()
        journal?.record("scene=background backgroundTime=\(narrations.backgroundStatus.logValue) audio=\(playing)")
        guard !narrations.continuesInBackground, !playing else { return }
        narrations.pauseIfBackgroundTimeNotGranted()
        pause(message: narrations.backgroundStatusMessage, reason: .leftApp)
    }

    /// Picks up a run iOS stopped, in the foreground. Each try that saves nothing new counts toward the limit, so a lasting error can't loop.
    func continueInterruptedRun(hostID: UUID, player: AudioPlayerService) async {
        await narrations.loadIfNeeded()
        // The scene may have left the screen or closed while saved audio loaded.
        guard !Task.isCancelled else { return }
        guard !isRunning, !narrations.isPreparing, narrations.preparationOwner == nil,
              let run = unfinished, let reason = run.reason, reason.continuesAutomatically else { return }
        let document = narrations.documents.first {
            $0.discourseID == run.discourseID && TranslatedListening.isSameVersion($0.selection, run.selection)
        }
        // A catalog update can remove the discourse; audio made for it could never be opened.
        if document?.isComplete == true || Catalog.discourseLookup[run.discourseID] == nil {
            forgetUnfinished()
            return
        }
        let progressed = (document?.segments.count ?? 0) > run.passagesAtStart
        guard progressed || run.automaticAttempts < Self.automaticAttemptLimit else {
            Self.log.info("Continue outcome=limitReached attempts=\(run.automaticAttempts, privacy: .public)")
            return
        }
        journal?.record("continue automatically after=\(reason.rawValue)")
        start(discourseID: run.discourseID, selection: run.selection, hostID: hostID, player: player, listen: false, automatic: true)
    }

    /// Renditions with every passage saved only need joining, which translates nothing, so they never wait for a tap.
    /// Returns once none is left; a translation the listener starts meanwhile stops the joins, and they're tried again later.
    func joinSavedPassages() async {
        await narrations.loadIfNeeded()
        while !Task.isCancelled, await joinNextSavedPassages() {}
    }

    /// False when nothing was joined to the end: none waiting, or the join was stopped or failed.
    private func joinNextSavedPassages() async -> Bool {
        guard !isRunning, joining == nil, !narrations.isPreparing, narrations.preparationOwner == nil,
              let document = narrations.documents.first(where: {
                  !$0.isComplete && $0.expectedSegmentCount > 0 && $0.segments.count == $0.expectedSegmentCount
                      && !joinAttempts.contains($0.id) && Catalog.discourseLookup[$0.discourseID] != nil
              }) else { return false }
        let owner = UUID()
        guard narrations.reservePreparation(owner: owner) else { return false }
        joinAttempts.insert(document.id)
        journal?.record("join saved passages discourse=\(document.discourseID) passages=\(document.segments.count)")
        let service = narrations
        let fetch = fetchTranscript
        let renderer = makeRenderer(document.selection)
        let task = Task { @MainActor [journal] in
            do {
                let transcript = try await fetch(document.discourseID)
                try Task.checkCancellation()
                // A changed transcript is a different rendition; its passages are translated afresh only on request.
                guard try NarrationCache.Plan(transcript: transcript, selection: document.selection).document.id == document.id else {
                    journal?.record("join skipped; the transcript changed")
                    service.releasePreparation(owner: owner)
                    return
                }
                _ = try await service.prepare(
                    transcript: transcript, selection: document.selection,
                    translate: { _ in throw NarrationPreparationError.invalidTranslation },
                    renderer: renderer, owner: owner
                )
                journal?.record("join finished")
            } catch {
                service.releasePreparation(owner: owner)
                journal?.record("join stopped error=\(NarrationJournal.describe(error))")
            }
        }
        joining = (owner, document.id, task)
        await task.value
        guard joining?.owner == owner else { return false }
        joining = nil
        return narrations.documents.first { $0.id == document.id }?.isComplete == true
    }

    /// Deleting a rendition also stops its translation, playback and any automatic restart, so nothing recreates it.
    func delete(_ document: NarrationDocument, player: AudioPlayerService) async throws {
        if player.currentNarration?.id == document.id { player.stop() }
        NarrationPreviewPlayback.shared.stopLoading(documentID: document.id)
        if joining?.documentID == document.id { stopJoining() }
        if isRunning, self.discourseID == document.discourseID, let selection,
           TranslatedListening.isSameVersion(selection, document.selection) {
            pause()
        }
        if unfinished?.matches(discourseID: document.discourseID, selection: document.selection) == true {
            unfinished = nil
            persist()
        }
        try await narrations.remove(document.id)
        journal?.record("deleted a saved translation")
    }

    private func stopJoining() {
        guard let joining else { return }
        self.joining = nil
        joinAttempts.remove(joining.documentID)
        joining.task.cancel()
        narrations.cancel(owner: joining.owner)
        narrations.releasePreparation(owner: joining.owner)
        journal?.record("join paused for another translation")
    }

    func forgetUnfinished(discourseID: String? = nil) {
        guard let run = unfinished, discourseID == nil || run.discourseID == discourseID, !isRunning else { return }
        unfinished = nil
        persist()
    }

    /// Why the version on screen stopped, when it is the one this controller last ran.
    func stopExplanation(discourseID: String, selection: NarrationSelection) -> (reason: NarrationStopReason, at: Date)? {
        guard !isRunning, let run = unfinished, run.matches(discourseID: discourseID, selection: selection),
              let reason = run.reason, let at = run.stoppedAt else { return nil }
        return (reason, at)
    }

    private func recordProgress(attempt: NarrationTranslationLifetime) {
        guard lifetime?.id == attempt.id, unfinished?.reason == nil else { return }
        unfinished?.lastProgressAt = now()
        persist()
    }

    private func markStopped(_ reason: NarrationStopReason, detail: String = "") {
        guard unfinished != nil, unfinished?.reason == nil else { return }
        unfinished?.reason = reason
        unfinished?.stoppedAt = now()
        persist()
        journal?.record("stopped reason=\(reason.rawValue) backgroundTime=\(narrations.backgroundStatus.logValue) lowPower=\(narrations.isLowPowerModeEnabled) \(detail)")
    }

    private func persist() {
        guard let defaults else { return }
        if let unfinished, let data = try? JSONEncoder().encode(unfinished) {
            defaults.set(data, forKey: Self.unfinishedRunKey)
        } else {
            defaults.removeObject(forKey: Self.unfinishedRunKey)
        }
    }

    private static func reason(for status: NarrationBackgroundStatus) -> NarrationStopReason {
        switch status {
        case .paused(.expired): .backgroundEnded
        case .paused(.preparationFailed): .failed
        case .paused(.cancelled): .interrupted
        case .paused: .leftApp
        default: .interrupted
        }
    }

    /// A completed first passage is enough to listen; a new track chosen meanwhile cancels that intent.
    func playWhenReady() {
        guard let autoplay, let selection, let discourseID else { return }
        guard autoplay.player.playbackGeneration == autoplay.generation,
              autoplay.player.playbackIntentGeneration == autoplay.intent else {
            self.autoplay = nil
            return
        }
        let service = narrations
        guard let document = service.documents.first(where: {
                  $0.discourseID == discourseID && TranslatedListening.isSameVersion($0.selection, selection)
              }),
              service.audioURL(for: document) != nil || service.playablePrefix(of: document.id) != nil else { return }
        self.autoplay = nil
        NarrationPreviewPlayback.shared.play(documentID: document.id, player: autoplay.player)
    }

    func checkServiceOwner() {
        guard let owner, isRunning, narrations.preparationOwner != owner else { return }
        // A successful run releases the lease just before returning its final document.
        if narrations.progress < 1 {
            pause(message: narrations.statusMessage, reason: Self.reason(for: narrations.backgroundStatus))
        }
    }

    private func retire() {
        lifetime?.invalidate()
        if let owner {
            narrations.cancel(owner: owner)
            narrations.releasePreparation(owner: owner)
        }
        owner = nil
        startup?.cancel()
        startup = nil
        work?.cancel()
        work = nil
        job = nil
        lifetime = nil
        autoplay = nil
    }

    private func failureMessage(_ error: Error) -> String {
        if let error = error as? NarrationTranslationError { return error.localizedDescription }
        if let error = error as? NarrationPreparationError { return error.localizedDescription }
        if let error = error as? NativeNarrationSpeechError { return error.localizedDescription }
        if stage == .fetchingTranscript { return "Couldn't load the transcript. Check your connection and try again." }
        return narrations.errorMessage ?? "Couldn't prepare the audio. Your finished passages are saved. Try again."
    }
}

private struct NarrationPreparationHostKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

extension EnvironmentValues {
    var narrationPreparationHostID: UUID? {
        get { self[NarrationPreparationHostKey.self] }
        set { self[NarrationPreparationHostKey.self] = newValue }
    }
}

@available(macCatalyst 26.0, *)
struct NarrationPreparationHost: View {
    let hostID: UUID
    @Environment(\.scenePhase) private var phase
    @Environment(AudioPlayerService.self) private var player
    private let controller = NarrationPreparationController.shared

    var body: some View {
        // Modifiers on an empty view don't run, so the host keeps a placeholder while no job exists.
        ZStack {
            Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
            if let job = controller.job, job.hostID == hostID {
                NarrationTranslationTaskHost(job: job)
                    .id(job.id)
            }
        }
        .onChange(of: phase) { _, value in
            if controller.isRunning || controller.unfinished != nil {
                NarrationJournal.shared.record("scene=\(Self.name(value)) running=\(controller.isRunning)")
            }
            controller.sceneChanged(value, hostID: hostID)
        }
        .onChange(of: NarrationService.shared.preparationOwner) { _, _ in controller.checkServiceOwner() }
        // On screen, and again whenever a run stops there: renew spent grace time, or continue a run iOS stopped.
        // A run frozen in the background can fail only after it returns to the screen.
        .task(id: ContinueTrigger(active: phase == .active, running: controller.isRunning)) {
            guard phase == .active else { return }
            NarrationService.shared.renewBackgroundTimeIfNeeded()
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, phase == .active else { return }
            await controller.joinSavedPassages()
            guard !Task.isCancelled, phase == .active else { return }
            await controller.continueInterruptedRun(hostID: hostID, player: player)
        }
    }

    private struct ContinueTrigger: Equatable {
        let active: Bool
        let running: Bool
    }

    private static func name(_ phase: ScenePhase) -> String {
        switch phase {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }
}

@available(macCatalyst 26.0, *)
private struct NarrationTranslationTaskHost: View {
    let job: NarrationTranslationJob
    @State private var started = false

    var body: some View {
        Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
            .translationTask(job.configuration) { @MainActor session in
                guard !started else { return }
                started = true
                let controller = NarrationPreparationController.shared
                do {
                    try job.lifetime.check()
                    controller.updateStage(.preparingLanguages, attempt: job.lifetime)
                    try await AppleNarrationTranslator.prepare(lifetime: job.lifetime) {
                        try await session.prepareTranslation()
                    }
                    try job.lifetime.check()
                    await controller.languagesReady(for: job, foregroundSession: session)
                } catch {
                    controller.finish(.failure(error), attempt: job.lifetime)
                }
            }
    }
}
#endif
