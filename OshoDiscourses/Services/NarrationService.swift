import Foundation
import Observation
import os

@Observable
@MainActor
final class NarrationService {
    static let shared: NarrationService = NarrationService(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("narrations", isDirectory: true),
        defaults: .standard,
        backgroundActivity: makeBackgroundActivity(),
        pacer: NarrationPausePacer(),
        audioKeepsAppRunning: { AppRuntime.shared.audioPlayer.isPlaying },
        passageAudioInUse: { (id: String) -> Bool in
            let player = AppRuntime.shared.audioPlayer
            return (player.isPlayingNarrationPreview && player.currentNarration?.id == id) || NarrationPreviewPlayback.shared.loadingDocumentID == id
        },
        journal: .shared
    )

    enum Event {
        case documentUpdated(NarrationDocument)
        case preparationEnded(documentID: String)
    }

    private(set) var documents: [NarrationDocument] = []
    /// When each rendition was last listened to, for Continue Listening; device-local like its position.
    private(set) var recentPlays: [String: Date] = [:]
    /// Changes whenever saved files are removed, so storage totals can refresh without a document change.
    private(set) var storageRevision = 0
    private(set) var isPreparing = false
    private(set) var preparationOwner: UUID?
    private(set) var progress = 0.0
    private(set) var statusMessage = ""
    private(set) var errorMessage: String?
    private(set) var preparingDiscourseID: String?
    private(set) var preparingDocumentID: String?
    private(set) var completedPassages = 0
    private(set) var totalPassages = 0
    private(set) var estimatedSecondsRemaining: TimeInterval?
    private(set) var backgroundStatus: NarrationBackgroundStatus = .idle
    private(set) var isLowPowerModeEnabled = false
    /// Submitted requests do not count; both submission and a usable attached task are required.
    var continuesInBackground: Bool { backgroundStatus == .running }
    var backgroundStatusMessage: String {
        guard backgroundStatus != .idle else { return "" }
        return backgroundStatus.message + (isLowPowerModeEnabled ? " Low Power Mode is on." : "")
    }
    @ObservationIgnored var onEvent: (@MainActor (Event) -> Void)?
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var timings: [String: NarrationOriginalTiming] = [:]

    @ObservationIgnored private let cache: NarrationCache
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let retrySleep: @MainActor (Duration) async throws -> Void
    @ObservationIgnored private let now: @MainActor () -> TimeInterval
    @ObservationIgnored private let lowPowerMode: @MainActor () -> Bool
    @ObservationIgnored private let backgroundActivity: (any NarrationBackgroundActivity)?
    @ObservationIgnored private let pacer: (any NarrationPacing)?
    @ObservationIgnored private let journal: NarrationJournal?
    @ObservationIgnored private let audioKeepsAppRunning: @MainActor () -> Bool
    @ObservationIgnored private let passageAudioInUse: @MainActor (String) -> Bool
    @ObservationIgnored private var estimator: NarrationProgressEstimator?
    @ObservationIgnored private var active: Preparation?
    @ObservationIgnored private var ready: [String: NarrationCache.Snapshot] = [:]
    @ObservationIgnored private var deletingIDs: Set<String> = []
    @ObservationIgnored private var deletingDiscourses: Set<String> = []
    @ObservationIgnored private var revision: UInt64 = 0
    private static let positionPrefix = "narration.position."
    private static let recentPlaysKey = "narration.recentPlays"
    private static let maximumRecentPlays = 20
    private static let log = Logger(subsystem: "com.agraabhi.oshodiscourses", category: "Narration")

    private final class Preparation {
        let job: NarrationCache.Job
        let owner: UUID?
        let documentID: String
        let discourseID: String
        let renderer: any NarrationSpeechRendering
        let selection: NarrationSelection
        /// Seconds each passage should last at Osho's pace, indexed by chunk; nil where unpaced.
        let paceTargets: [TimeInterval?]
        let onFailure: (@MainActor (Error) -> Void)?
        let onProgress: (@MainActor (NarrationDocument) -> Void)?
        var rendererCancelled = false
        var failure: WorkFailure?

        init(
            job: NarrationCache.Job, owner: UUID?, documentID: String, discourseID: String,
            renderer: any NarrationSpeechRendering, selection: NarrationSelection, paceTargets: [TimeInterval?],
            onFailure: (@MainActor (Error) -> Void)?, onProgress: (@MainActor (NarrationDocument) -> Void)?
        ) {
            self.selection = selection
            self.paceTargets = paceTargets
            self.job = job
            self.owner = owner
            self.documentID = documentID
            self.discourseID = discourseID
            self.renderer = renderer
            self.onFailure = onFailure
            self.onProgress = onProgress
        }
    }

    private enum Stage: String, Sendable {
        case cache, translation, rendering, checkpoint, assembly

        var failureMessage: String {
            switch self {
            case .cache, .checkpoint: NarrationPreparationError.storage.localizedDescription
            case .translation: "Translation could not finish. Saved passages can be reused when you retry."
            case .rendering, .assembly: NarrationPreparationError.invalidAudio.localizedDescription
            }
        }
    }

    private struct WorkFailure: Error {
        let stage: Stage
        let underlying: Error
    }

    private struct TranslatedBatch: Sendable {
        let chunks: [NarrationCache.Chunk]
        let texts: [String]
    }

    init(
        directory: URL, defaults: UserDefaults,
        retrySleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        backgroundActivity: (any NarrationBackgroundActivity)? = nil,
        pacer: (any NarrationPacing)? = nil,
        lowPowerMode: @escaping @MainActor () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled },
        audioKeepsAppRunning: @escaping @MainActor () -> Bool = { false },
        passageAudioInUse: @escaping @MainActor (String) -> Bool = { _ in false },
        journal: NarrationJournal? = nil
    ) {
        self.pacer = pacer
        self.passageAudioInUse = passageAudioInUse
        self.journal = journal
        self.audioKeepsAppRunning = audioKeepsAppRunning
        cache = NarrationCache(directory: directory)
        self.defaults = defaults
        self.retrySleep = retrySleep
        self.now = now
        self.lowPowerMode = lowPowerMode
        isLowPowerModeEnabled = lowPowerMode()
        self.backgroundActivity = backgroundActivity
        let saved = defaults.dictionary(forKey: Self.recentPlaysKey) as? [String: Double] ?? [:]
        recentPlays = saved.reduce(into: [:]) { plays, entry in
            if NarrationCache.isID(entry.key), entry.value.isFinite { plays[entry.key] = Date(timeIntervalSince1970: entry.value) }
        }
    }

    func recordPlay(documentID: String, at date: Date = Date()) {
        guard NarrationCache.isID(documentID) else { return }
        recentPlays[documentID] = date
        if recentPlays.count > Self.maximumRecentPlays,
           let oldest = recentPlays.min(by: { $0.value < $1.value })?.key {
            recentPlays[oldest] = nil
        }
        persistRecentPlays()
    }

    func dismissFromRecent(documentID: String) {
        guard recentPlays.removeValue(forKey: documentID) != nil else { return }
        persistRecentPlays()
    }

    private func persistRecentPlays() {
        defaults.set(recentPlays.mapValues(\.timeIntervalSince1970), forKey: Self.recentPlaysKey)
    }

    private static func makeBackgroundActivity() -> (any NarrationBackgroundActivity)? {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        return NarrationGraceTime.system()
        #endif
        return nil
    }

    /// Verifying saved audio reads every file, so screens that only show status load once per launch.
    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await load()
    }

    func load() async {
        guard active == nil, deletingIDs.isEmpty, deletingDiscourses.isEmpty else { return }
        let started = revision
        do {
            let snapshots = try await cache.load()
            guard revision == started, !Task.isCancelled else { return }
            documents = snapshots.map(\.document).sorted(by: Self.mostRecent)
            ready = Dictionary(uniqueKeysWithValues: snapshots.filter { $0.document.isComplete }.map { ($0.document.id, $0) })
            errorMessage = nil
            hasLoaded = true
            revision &+= 1
            Self.log.info("stage=load outcome=loaded")
            await removeSpentPassageAudio()
        } catch is CancellationError {
            Self.log.debug("stage=load outcome=cancelled")
        } catch {
            guard revision == started else { return }
            ready.removeAll()
            for index in documents.indices {
                documents[index].audioFileName = nil
                documents[index].duration = 0
            }
            revision &+= 1
            errorMessage = "Saved translations couldn't be loaded. Please try again."
            Self.log.error("stage=load outcome=failed")
        }
    }

    // Reserve before awaiting native consent or preflight; a window cannot claim another window's attempt.
    func reservePreparation(owner: UUID) -> Bool {
        if let preparationOwner { return preparationOwner == owner }
        guard active == nil else { return false }
        preparationOwner = owner
        revision &+= 1
        Self.log.debug("stage=reservation outcome=reserved")
        return true
    }

    func releasePreparation(owner: UUID) {
        guard preparationOwner == owner, active == nil else { return }
        preparationOwner = nil
        revision &+= 1
        Self.log.debug("stage=reservation outcome=released")
    }

    func prepare(
        transcript: Transcript,
        selection: NarrationSelection,
        translate: @escaping @MainActor ([String]) async throws -> [String],
        renderer: any NarrationSpeechRendering,
        owner: UUID? = nil,
        onFailure: (@MainActor (Error) -> Void)? = nil,
        onProgress: (@MainActor (NarrationDocument) -> Void)? = nil
    ) async throws -> NarrationDocument {
        try Task.checkCancellation()
        if let owner {
            // A cancelled preflight must never implicitly reacquire its reservation.
            guard preparationOwner == owner else { throw CancellationError() }
        } else if preparationOwner != nil {
            throw NarrationPreparationError.busy
        }
        guard active == nil, !deletingDiscourses.contains(transcript.discourseID) else {
            Self.log.debug("stage=prepare outcome=busy")
            throw NarrationPreparationError.busy
        }
        let plan: NarrationCache.Plan
        do {
            plan = try NarrationCache.Plan(transcript: transcript, selection: selection)
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Preparation could not start."
            Self.log.notice("stage=prepare outcome=invalidInput")
            throw error
        }
        guard !deletingIDs.contains(plan.document.id) else { throw NarrationPreparationError.busy }
        let job = NarrationCache.Job()
        let paceTargets: [TimeInterval?] = selection.pace == .osho && pacer != nil
            ? NarrationPacingTargets.durations(
                chunks: plan.chunks.map { ($0.sourceParagraphIndex, $0.text.count) },
                timing: NarrationOriginalTiming.make(transcript: transcript)
            )
            : []
        let preparation = Preparation(
            job: job, owner: owner, documentID: plan.document.id, discourseID: transcript.discourseID,
            renderer: renderer, selection: selection, paceTargets: paceTargets, onFailure: onFailure, onProgress: onProgress
        )
        active = preparation
        revision &+= 1
        isPreparing = true
        preparingDiscourseID = transcript.discourseID
        preparingDocumentID = plan.document.id
        progress = 0
        statusMessage = "Checking the saved translation…"
        errorMessage = nil
        let lengths = plan.chunks.map { $0.text.utf16.count }
        estimator = NarrationProgressEstimator(lengths: lengths, completed: [], startedAt: now())
        totalPassages = plan.chunks.count
        completedPassages = 0
        estimatedSecondsRemaining = nil
        beginBackground(selection: selection, job: job)
        let started = ProcessInfo.processInfo.systemUptime

        // Only one structured audio batch runs alongside the translation host's task.
        return try await withTaskCancellationHandler {
            var stage = Stage.cache
            do {
                var snapshot = try await cache.start(plan: plan, job: job)
                try check(job)
                if snapshot.document.isComplete {
                    Self.log.info("stage=cache outcome=hit")
                } else {
                    estimator = NarrationProgressEstimator(
                        lengths: lengths, completed: Set(snapshot.document.segments.map(\.index)), startedAt: now()
                    )
                    publish(snapshot)
                    Self.log.info("stage=cache outcome=\(snapshot.document.segments.isEmpty ? "miss" : "resumed", privacy: .public)")
                    journal?.record("prepare from=\(snapshot.document.segments.count)/\(plan.chunks.count) lowPower=\(isLowPowerModeEnabled)")
                    let completed = Set(snapshot.document.segments.map(\.index))
                    let missing = plan.chunks.filter { !completed.contains($0.index) }
                    let batches = Self.batches(missing)
                    let savedTranslations = try await cache.pendingTranslations(job: job)
                    try check(job)
                    recordTranslated(savedTranslations.keys, total: plan.chunks.count)
                    Self.log.info("stage=pipeline lookahead=\(batches.count > 1 ? 1 : 0, privacy: .public)")
                    if let first = batches.first {
                        var translated = try await translatedBatch(
                            first, saved: savedTranslations, total: plan.chunks.count, showProgress: true,
                            job: job, translate: translate
                        )
                        try check(job)
                        for index in batches.indices {
                            try check(job)
                            if index + 1 < batches.count {
                                let current = translated
                                async let rendered = renderBatch(
                                    current, total: plan.chunks.count, selection: selection, job: job
                                )
                                let next = try await translatedBatch(
                                    batches[index + 1], saved: savedTranslations, total: plan.chunks.count, showProgress: false,
                                    job: job, translate: translate
                                )
                                try check(job)
                                snapshot = try await rendered
                                try check(job)
                                translated = next
                            } else {
                                snapshot = try await renderBatch(
                                    translated, total: plan.chunks.count, selection: selection, job: job
                                )
                                try check(job)
                            }
                        }
                    }
                    try check(job)
                    stage = .assembly
                    statusMessage = "Finishing the translation…"
                    estimatedSecondsRemaining = nil
                    if backgroundStatus == .requesting || continuesInBackground {
                        backgroundActivity?.update(fraction: progress, subtitle: "Finishing the audio…")
                    }
                    let segments = try await cache.segmentURLs(job: job)
                    try check(job)
                    let output = try await cache.outputURL(segment: nil, job: job)
                    try check(job)
                    let duration = try await renderer.assemble(segments: segments, to: output)
                    try check(job)
                    snapshot = try await cache.finish(duration: duration, job: job)
                    try check(job)
                }
                await cache.discardStaging(job: job)
                try check(job)
                publish(snapshot)
                active = nil
                preparationOwner = nil
                isPreparing = false
                preparingDiscourseID = nil
                progress = 1
                statusMessage = "Translation ready."
                endRun(documentID: plan.document.id, success: true)
                journal?.record("prepare ready")
                Self.log.info("stage=prepare outcome=ready seconds=\(ProcessInfo.processInfo.systemUptime - started, privacy: .public)")
                await removeSpentPassageAudio()
                return snapshot.document
            } catch {
                let failure = preparation.failure ?? (error as? WorkFailure) ?? WorkFailure(stage: stage, underlying: error)
                let error = failure.underlying
                let cancelled = preparation.failure == nil && (job.isCancelled || Task.isCancelled || error is CancellationError)
                if active?.job.id == job.id {
                    if cancelled {
                        cancel(job: job)
                    } else {
                        fail(failure, job: job)
                    }
                }
                await cache.discardStaging(job: job)
                if cancelled {
                    Self.log.info("stage=prepare outcome=cancelled")
                    throw CancellationError()
                }
                Self.log.error("stage=\(failure.stage.rawValue, privacy: .public) outcome=failed")
                throw error
            }
        } onCancel: { [weak self] in
            job.cancel()
            Task { @MainActor in self?.cancel(job: job) }
        }
    }

    private static func batches(_ chunks: [NarrationCache.Chunk]) -> [[NarrationCache.Chunk]] {
        var batches: [[NarrationCache.Chunk]] = []
        var batch: [NarrationCache.Chunk] = []
        var length = 0
        for chunk in chunks {
            if !batch.isEmpty, batch.count == 4 || length + chunk.text.utf16.count > 6_000 {
                batches.append(batch)
                batch = []
                length = 0
            }
            batch.append(chunk)
            length += chunk.text.utf16.count
        }
        if !batch.isEmpty { batches.append(batch) }
        return batches
    }

    private func translatedBatch(
        _ chunks: [NarrationCache.Chunk], saved: [Int: String], total: Int, showProgress: Bool,
        job: NarrationCache.Job, translate: @MainActor ([String]) async throws -> [String]
    ) async throws -> TranslatedBatch {
        var stage = Stage.translation
        do {
            try check(job)
            let missing = chunks.filter { saved[$0.index] == nil }
            var texts = saved
            if !missing.isEmpty {
                if showProgress { statusMessage = "Translating passage \(missing[0].index + 1) of \(total)…" }
                let response = try await translate(missing.map(\.text))
                try check(job)
                let translated = response.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard translated.count == missing.count, translated.allSatisfy({ !$0.isEmpty }) else {
                    throw NarrationPreparationError.invalidTranslation
                }
                let additions = Dictionary(uniqueKeysWithValues: zip(missing.map(\.index), translated))
                stage = .checkpoint
                try await cache.saveTranslations(additions, job: job)
                try check(job)
                texts.merge(additions) { _, translated in translated }
                recordTranslated(additions.keys, total: total)
                Self.log.debug("stage=translation outcome=translated")
            }
            Self.log.debug("stage=translationCache reused=\(chunks.count - missing.count, privacy: .public)")
            return TranslatedBatch(chunks: chunks, texts: try chunks.map {
                guard let text = texts[$0.index] else { throw NarrationPreparationError.invalidTranslation }
                return text
            })
        } catch {
            throw WorkFailure(stage: stage, underlying: error)
        }
    }

    private func renderBatch(
        _ batch: TranslatedBatch, total: Int, selection: NarrationSelection, job: NarrationCache.Job
    ) async throws -> NarrationCache.Snapshot {
        try await withTaskCancellationHandler {
            var stage = Stage.rendering
            do {
                try check(job)
                guard let renderer = active?.renderer else { throw CancellationError() }
                var snapshot: NarrationCache.Snapshot?
                for (chunk, text) in zip(batch.chunks, batch.texts) {
                    try check(job)
                    stage = .rendering
                    let target = active?.paceTargets.indices.contains(chunk.index) == true ? active?.paceTargets[chunk.index] : nil
                    let duration = try await renderPassage(
                        text, index: chunk.index, total: total, voiceID: selection.voice.id, target: target,
                        renderer: renderer, job: job
                    )
                    try check(job)
                    stage = .checkpoint
                    let saved = try await cache.checkpoint(index: chunk.index, text: text, duration: duration, job: job)
                    try check(job)
                    estimator?.complete(chunk.index, at: now())
                    journal?.record("passage \(saved.document.segments.count)/\(total) backgroundTime=\(backgroundStatus.logValue)")
                    publish(saved)
                    snapshot = saved
                    Self.log.debug("stage=checkpoint outcome=saved")
                }
                guard let snapshot else { throw NarrationPreparationError.invalidTranslation }
                return snapshot
            } catch {
                let failure = WorkFailure(stage: stage, underlying: error)
                fail(failure, job: job)
                throw failure
            }
        } onCancel: { [weak self] in
            // A failed lookahead must also release a renderer awaiting native callbacks.
            Task { @MainActor in self?.stopRenderer(job: job) }
        }
    }

    private func renderPassage(
        _ text: String, index: Int, total: Int, voiceID: String, target: TimeInterval?,
        renderer: any NarrationSpeechRendering, job: NarrationCache.Job
    ) async throws -> TimeInterval {
        var retries = 0
        while true {
            try check(job)
            statusMessage = "Creating audio \(index + 1) of \(total)…"
            let output = try await cache.outputURL(segment: index, job: job)
            try check(job)
            // The voice renders beside the final file; pacing writes the passage that is kept.
            let unpaced = output.deletingLastPathComponent().appendingPathComponent(".unpaced-\(index).m4a")
            let pacing = target.flatMap { target in pacer.map { ($0, target) } }
            do {
                defer { if pacing != nil { try? FileManager.default.removeItem(at: unpaced) } }
                var duration = try await renderer.render(text: text, voiceID: voiceID, to: pacing == nil ? output : unpaced)
                try check(job)
                if let (pacer, target) = pacing {
                    duration = try await pacer.pace(unpaced, to: output, targetDuration: target)
                    try check(job)
                }
                Self.log.debug("stage=rendering outcome=succeeded paced=\(pacing != nil, privacy: .public) retries=\(retries, privacy: .public)")
                return duration
            } catch {
                try check(job)
                let retryable = (error as? NativeNarrationSpeechError).map {
                    [.timedOut, .noAudio, .incompleteAudio].contains($0)
                } ?? false
                guard retryable, retries == 0 else {
                    Self.log.error("stage=rendering outcome=failed retryable=\(retryable, privacy: .public) retries=\(retries, privacy: .public)")
                    throw error
                }
                try await cache.discardOutput(segment: index, job: job)
                try check(job)
                retries += 1
                statusMessage = "Retrying audio \(index + 1) of \(total)…"
                Self.log.info("stage=rendering outcome=retrying retries=\(retries, privacy: .public)")
                try await retrySleep(.milliseconds(500))
                try check(job)
            }
        }
    }

    func cancel(owner: UUID) {
        guard preparationOwner == owner else { return }
        cancel()
    }

    func cancel() {
        if let active {
            cancel(job: active.job)
        } else if preparationOwner != nil {
            preparationOwner = nil
            revision &+= 1
            Self.log.debug("stage=reservation outcome=cancelled")
        }
    }

    /// Playing audio keeps the app running in the background, so preparation needs no background task then.
    func pauseIfBackgroundTimeNotGranted(audioKeepsAppRunning: Bool = false) {
        refreshPowerState()
        Self.log.info("stage=backgroundEntry granted=\(self.continuesInBackground, privacy: .public) audio=\(audioKeepsAppRunning, privacy: .public) lowPower=\(self.isLowPowerModeEnabled, privacy: .public)")
        guard active != nil || preparationOwner != nil else { return }
        journal?.record("app entered background backgroundTime=\(backgroundStatus.logValue) audio=\(audioKeepsAppRunning) lowPower=\(isLowPowerModeEnabled)")
        guard !continuesInBackground, !audioKeepsAppRunning else { return }
        let reason: NarrationBackgroundReason
        if case .unavailable(let unavailable) = backgroundStatus {
            reason = unavailable
        } else {
            reason = .notGranted
        }
        setBackgroundStatus(.paused(reason))
        cancel()
        statusMessage = backgroundStatusMessage
    }

    func audioURL(for document: NarrationDocument) -> URL? {
        guard document.isComplete, !deletingIDs.contains(document.id),
              !deletingDiscourses.contains(document.discourseID),
              let snapshot = ready[document.id], snapshot.document == document else { return nil }
        guard let url = cache.audioURL(for: snapshot) else {
            ready[document.id] = nil
            if let index = documents.firstIndex(where: { $0.id == document.id }) {
                documents[index].audioFileName = nil
                documents[index].duration = 0
            }
            revision &+= 1
            Self.log.notice("stage=playback outcome=invalidCache")
            return nil
        }
        return url
    }

    func remove(_ id: String) async throws {
        guard NarrationCache.isID(id) else { throw NarrationPreparationError.storage }
        guard !deletingIDs.contains(id) else { throw NarrationPreparationError.busy }
        deletingIDs.insert(id)
        if active?.documentID == id { cancel() }
        forget(id)
        revision &+= 1
        let started = revision
        defer { deletingIDs.remove(id) }
        do {
            try await cache.remove(id)
            storageRevision &+= 1
            Self.log.info("stage=delete outcome=removed")
        } catch {
            if revision == started { errorMessage = "The translation couldn't be removed. Please try again." }
            Self.log.error("stage=delete outcome=failed")
            throw error
        }
    }

    func removeAll(for discourseID: String) async {
        guard !deletingDiscourses.contains(discourseID) else { return }
        deletingDiscourses.insert(discourseID)
        let runningID = active?.discourseID == discourseID ? active?.documentID : nil
        if runningID != nil { cancel() }
        var ids = Set(documents.filter { $0.discourseID == discourseID }.map(\.id))
        if let runningID { ids.insert(runningID) }
        for id in ids { forget(id) }
        revision &+= 1
        let started = revision
        defer { deletingDiscourses.remove(discourseID) }
        do {
            ids.formUnion(try await cache.ids(for: discourseID))
            var failed = false
            for id in ids {
                forget(id)
                do { try await cache.remove(id) } catch { failed = true }
            }
            if failed { throw NarrationPreparationError.storage }
            Self.log.info("stage=deleteAll outcome=removed")
        } catch {
            if revision == started { errorMessage = "Some translations couldn't be removed. Please try again." }
            Self.log.error("stage=deleteAll outcome=failed")
        }
    }

    /// A finished rendition plays from its joined file, so its passage files only take space.
    /// Passages that are playing, or about to, are kept until a later call.
    func removeSpentPassageAudio() async {
        for (id, snapshot) in ready where snapshot.hasPassageAudio {
            guard active?.documentID != id, !deletingIDs.contains(id),
                  !deletingDiscourses.contains(snapshot.document.discourseID), !passageAudioInUse(id) else { continue }
            do {
                guard let compacted = try await cache.removePassageAudio(of: snapshot),
                      ready[id]?.document == snapshot.document, !deletingIDs.contains(id) else { continue }
                ready[id] = compacted
                storageRevision &+= 1
                journal?.record("passage audio removed after joining passages=\(snapshot.document.segments.count)")
                Self.log.info("stage=compact outcome=removed")
            } catch {
                Self.log.error("stage=compact outcome=failed")
            }
        }
    }

    /// Bytes on disk for each saved rendition, keyed by document ID.
    func storageSizes() async -> [String: Int64] {
        await cache.sizes()
    }

    func savePosition(documentID: String, position: TimeInterval) {
        guard NarrationCache.isID(documentID), position.isFinite, position >= 0 else { return }
        let limit: TimeInterval
        if let document = ready[documentID]?.document {
            limit = document.duration
        } else if let partial = playablePrefix(of: documentID)?.document {
            // A partly prepared rendition resumes inside its finished passages, then continues once complete.
            limit = partial.duration
        } else {
            return
        }
        let clamped = min(position, limit)
        // Listening moves a rendition up Continue Listening; a paused autosave does not.
        if recentPlays[documentID] != nil, abs(self.position(for: documentID) - clamped) > 0.01 { recordPlay(documentID: documentID) }
        defaults.set(clamped, forKey: Self.positionPrefix + documentID)
    }

    func position(for documentID: String) -> TimeInterval {
        guard NarrationCache.isID(documentID) else { return 0 }
        let saved = defaults.double(forKey: Self.positionPrefix + documentID)
        guard saved.isFinite, saved >= 0 else { return 0 }
        return min(saved, ready[documentID]?.document.duration ?? saved)
    }

    /// Maps this rendition's time to the original recording's, paragraph by paragraph, without its audio.
    func timeline(for document: NarrationDocument) async -> NarrationTimeline? {
        let timing: NarrationOriginalTiming
        if let cached = timings[document.discourseID] {
            timing = cached
        } else {
            guard let transcript = try? await TranscriptService.shared.transcript(for: document.discourseID),
                  let made = NarrationOriginalTiming.make(transcript: transcript) else { return nil }
            timings[document.discourseID] = made
            timing = made
        }
        return NarrationTimeline(segments: document.segments, timing: timing, lastParagraphComplete: document.isComplete)
    }

    /// The finished passages from the start, which can play before the full narration exists.
    func playablePrefix(of documentID: String) -> (document: NarrationDocument, segmentURLs: [URL])? {
        guard NarrationCache.isID(documentID), !deletingIDs.contains(documentID),
              ready[documentID]?.hasPassageAudio != false,
              var document = documents.first(where: { $0.id == documentID }),
              !deletingDiscourses.contains(document.discourseID) else { return nil }
        let segments = zip(document.segments, 0...).prefix { $0.0.index == $0.1 && $0.0.duration.isFinite && $0.0.duration > 0 }
            .map(\.0)
        guard !segments.isEmpty else { return nil }
        document.segments = segments
        document.audioFileName = nil
        document.duration = segments.reduce(0) { $0 + $1.duration }
        return (document, segments.map { cache.segmentURL(documentID: documentID, index: $0.index) })
    }

    private func beginBackground(selection: NarrationSelection, job: NarrationCache.Job) {
        guard let backgroundActivity else {
            setBackgroundStatus(.unavailable(.notSupported))
            return
        }
        setBackgroundStatus(.requesting)
        let language = NarrationLanguageSupport.displayName(for: selection.targetLanguage)
        backgroundActivity.begin(
            title: "Translating into \(language)", subtitle: "Starting…",
            onStatusChange: { [weak self] status in
                guard let self, self.active?.job.id == job.id else { return }
                self.setBackgroundStatus(status)
            },
            onExpire: { [weak self] in self?.backgroundExpired(job: job) }
        )
    }

    /// Asks for the grace time again when the app returns; it is spent once used up in the background.
    func renewBackgroundTimeIfNeeded() {
        guard let active, backgroundStatus != .running else { return }
        journal?.record("background time renewed")
        beginBackground(selection: active.selection, job: active.job)
    }

    private func backgroundExpired(job: NarrationCache.Job) {
        guard active?.job.id == job.id else { return }
        // Playing audio keeps the app running, so the work outlives the grace time.
        if audioKeepsAppRunning() {
            journal?.record("background time expired; audio keeps translating")
            setBackgroundStatus(.paused(.expired))
            return
        }
        journal?.record("background time expired")
        setBackgroundStatus(.paused(.expired))
        cancel(job: job)
        statusMessage = "Preparation was stopped in the background. Completed passages are saved."
    }

    private func endRun(documentID: String, success: Bool) {
        backgroundActivity?.end(success: success)
        if success {
            setBackgroundStatus(.idle)
        } else {
            switch backgroundStatus {
            case .paused: break
            default: setBackgroundStatus(.paused(.cancelled))
            }
        }
        estimator = nil
        estimatedSecondsRemaining = nil
        preparingDocumentID = nil
        onEvent?(.preparationEnded(documentID: documentID))
    }

    private func setBackgroundStatus(_ status: NarrationBackgroundStatus) {
        refreshPowerState()
        guard backgroundStatus != status else { return }
        backgroundStatus = status
        if status != .idle { journal?.record("background status=\(status.logValue) lowPower=\(isLowPowerModeEnabled)") }
        Self.log.info("stage=background outcome=\(status.logValue, privacy: .public) lowPower=\(self.isLowPowerModeEnabled, privacy: .public)")
    }

    func refreshPowerState() {
        let enabled = lowPowerMode()
        guard enabled != isLowPowerModeEnabled else { return }
        isLowPowerModeEnabled = enabled
        Self.log.info("stage=power lowPower=\(enabled, privacy: .public)")
    }

    private func cancel(job: NarrationCache.Job) {
        guard let preparation = active, preparation.job.id == job.id else { return }
        job.cancel()
        stopRenderer(job: job)
        active = nil
        preparationOwner = nil
        isPreparing = false
        preparingDiscourseID = nil
        errorMessage = nil
        statusMessage = "Preparation paused. Saved text and audio will be reused."
        revision &+= 1
        endRun(documentID: preparation.documentID, success: false)
        Self.log.debug("stage=prepare outcome=paused")
        Task { await cache.discardStaging(job: job) }
    }

    private func stopRenderer(job: NarrationCache.Job) {
        guard let preparation = active, preparation.job.id == job.id, !preparation.rendererCancelled else { return }
        active?.rendererCancelled = true
        preparation.renderer.cancel()
    }

    private func fail(_ failure: WorkFailure, job: NarrationCache.Job) {
        guard let preparation = active, preparation.job.id == job.id, preparation.failure == nil,
              !job.isCancelled, !Task.isCancelled, !(failure.underlying is CancellationError) else { return }
        preparation.failure = failure
        stopRenderer(job: job)
        job.cancel()
        active = nil
        preparationOwner = nil
        isPreparing = false
        preparingDiscourseID = nil
        errorMessage = (failure.underlying as? NarrationPreparationError)?.localizedDescription
            ?? (failure.underlying as? NativeNarrationSpeechError)?.localizedDescription ?? failure.stage.failureMessage
        statusMessage = "Preparation paused. Saved text and audio will be reused."
        revision &+= 1
        setBackgroundStatus(.paused(.preparationFailed))
        endRun(documentID: preparation.documentID, success: false)
        Task { await cache.discardStaging(job: job) }
        // Retire the view's session promptly; a native lookahead may still be awaiting consent or a response.
        preparation.onFailure?(failure.underlying)
        journal?.record("prepare failed stage=\(failure.stage.rawValue) error=\(NarrationJournal.describe(failure.underlying))")
        Self.log.notice("stage=pipeline outcome=stopped reason=\(failure.stage.rawValue, privacy: .public)")
    }

    private func check(_ job: NarrationCache.Job) throws {
        try job.check()
        guard let preparation = active, preparation.job.id == job.id,
              preparation.owner == preparationOwner else { throw CancellationError() }
    }

    private func publish(_ snapshot: NarrationCache.Snapshot) {
        refreshPowerState()
        documents.removeAll { $0.id == snapshot.document.id }
        documents.append(snapshot.document)
        documents.sort(by: Self.mostRecent)
        ready[snapshot.document.id] = snapshot.document.isComplete ? snapshot : nil
        let expected = snapshot.document.expectedSegmentCount
        if snapshot.document.isComplete {
            progress = 1
        } else if let estimator, estimator.passageCount == expected {
            // The final share is reserved for joining passages into one file.
            progress = estimator.workFraction * Double(expected) / Double(expected + 1)
        } else {
            progress = Double(snapshot.document.segments.count) / Double(expected + 1)
        }
        if active?.documentID == snapshot.document.id {
            completedPassages = snapshot.document.segments.count
            totalPassages = expected
            estimatedSecondsRemaining = snapshot.document.isComplete ? nil : estimator?.secondsRemaining
            if !snapshot.document.isComplete { reportBackgroundProgress() }
        }
        revision &+= 1
        onEvent?(.documentUpdated(snapshot.document))
        if active?.documentID == snapshot.document.id { active?.onProgress?(snapshot.document) }
    }

    private func reportBackgroundProgress() {
        guard backgroundStatus == .requesting || continuesInBackground else { return }
        var subtitle = NarrationTimeFormatting.passages(completedPassages, of: totalPassages)
        if let estimatedSecondsRemaining { subtitle += " · " + NarrationTimeFormatting.remaining(estimatedSecondsRemaining) }
        backgroundActivity?.update(fraction: progress, subtitle: subtitle)
    }

    /// A finished translation batch is real progress before any of its audio exists.
    private func recordTranslated(_ indices: some Sequence<Int>, total: Int) {
        guard var estimator, estimator.passageCount == total else { return }
        estimator.markTranslated(indices)
        self.estimator = estimator
        progress = max(progress, estimator.workFraction * Double(total) / Double(total + 1))
        reportBackgroundProgress()
    }

    private func forget(_ id: String) {
        documents.removeAll { $0.id == id }
        ready[id] = nil
        defaults.removeObject(forKey: Self.positionPrefix + id)
        dismissFromRecent(documentID: id)
    }

    private static func mostRecent(_ lhs: NarrationDocument, _ rhs: NarrationDocument) -> Bool {
        lhs.updatedAt == rhs.updatedAt ? lhs.id < rhs.id : lhs.updatedAt > rhs.updatedAt
    }
}
