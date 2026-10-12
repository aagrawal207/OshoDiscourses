import Foundation
import Observation
import os

@Observable
@MainActor
final class NarrationService {
    static let shared = NarrationService(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("narrations", isDirectory: true),
        defaults: .standard,
        backgroundActivity: makeBackgroundActivity()
    )

    enum Event {
        case documentUpdated(NarrationDocument)
        case preparationEnded(documentID: String)
    }

    private(set) var documents: [NarrationDocument] = []
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
    /// True only while the system has accepted the work; otherwise leaving the app must pause it.
    private(set) var continuesInBackground = false
    @ObservationIgnored var onEvent: (@MainActor (Event) -> Void)?

    @ObservationIgnored private let cache: NarrationCache
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let retrySleep: @MainActor (Duration) async throws -> Void
    @ObservationIgnored private let now: @MainActor () -> TimeInterval
    @ObservationIgnored private let backgroundActivity: (any NarrationBackgroundActivity)?
    @ObservationIgnored private var estimator: NarrationProgressEstimator?
    @ObservationIgnored private var active: Preparation?
    @ObservationIgnored private var ready: [String: NarrationCache.Snapshot] = [:]
    @ObservationIgnored private var deletingIDs: Set<String> = []
    @ObservationIgnored private var deletingDiscourses: Set<String> = []
    @ObservationIgnored private var revision: UInt64 = 0
    private static let positionPrefix = "narration.position."
    private static let log = Logger(subsystem: "com.agraabhi.oshodiscourses", category: "Narration")

    private final class Preparation {
        let job: NarrationCache.Job
        let owner: UUID?
        let documentID: String
        let discourseID: String
        let renderer: any NarrationSpeechRendering
        let onFailure: (@MainActor (Error) -> Void)?
        var rendererCancelled = false
        var failure: WorkFailure?

        init(
            job: NarrationCache.Job, owner: UUID?, documentID: String, discourseID: String,
            renderer: any NarrationSpeechRendering, onFailure: (@MainActor (Error) -> Void)?
        ) {
            self.job = job
            self.owner = owner
            self.documentID = documentID
            self.discourseID = discourseID
            self.renderer = renderer
            self.onFailure = onFailure
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
        backgroundActivity: (any NarrationBackgroundActivity)? = nil
    ) {
        cache = NarrationCache(directory: directory)
        self.defaults = defaults
        self.retrySleep = retrySleep
        self.now = now
        self.backgroundActivity = backgroundActivity
    }

    private static func makeBackgroundActivity() -> (any NarrationBackgroundActivity)? {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) { return NarrationContinuedProcessing() }
        #endif
        return nil
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
            revision &+= 1
            Self.log.info("stage=load outcome=loaded")
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
            errorMessage = "Saved narration could not be loaded. Please try again."
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
        onFailure: (@MainActor (Error) -> Void)? = nil
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
        let preparation = Preparation(
            job: job, owner: owner, documentID: plan.document.id, discourseID: transcript.discourseID,
            renderer: renderer, onFailure: onFailure
        )
        active = preparation
        revision &+= 1
        isPreparing = true
        preparingDiscourseID = transcript.discourseID
        preparingDocumentID = plan.document.id
        progress = 0
        statusMessage = "Checking saved narration…"
        errorMessage = nil
        let lengths = plan.chunks.map { $0.text.utf16.count }
        estimator = NarrationProgressEstimator(lengths: lengths, completed: [], startedAt: now())
        totalPassages = plan.chunks.count
        completedPassages = 0
        estimatedSecondsRemaining = nil
        beginBackground(selection: selection, job: job)
        let started = ProcessInfo.processInfo.systemUptime

        // Native translation stays in the view's task; only one structured audio batch runs alongside it.
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
                    let completed = Set(snapshot.document.segments.map(\.index))
                    let missing = plan.chunks.filter { !completed.contains($0.index) }
                    let batches = Self.batches(missing)
                    let savedTranslations = try await cache.pendingTranslations(job: job)
                    try check(job)
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
                    statusMessage = "Finishing narration…"
                    estimatedSecondsRemaining = nil
                    if continuesInBackground { backgroundActivity?.update(fraction: progress, subtitle: "Finishing the audio…") }
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
                statusMessage = "Narration ready."
                endRun(documentID: plan.document.id, success: true)
                Self.log.info("stage=prepare outcome=ready seconds=\(ProcessInfo.processInfo.systemUptime - started, privacy: .public)")
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
                    let duration = try await renderPassage(
                        text, index: chunk.index, total: total, voiceID: selection.voice.id, renderer: renderer, job: job
                    )
                    try check(job)
                    stage = .checkpoint
                    let saved = try await cache.checkpoint(index: chunk.index, text: text, duration: duration, job: job)
                    try check(job)
                    estimator?.complete(chunk.index, at: now())
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
        _ text: String, index: Int, total: Int, voiceID: String,
        renderer: any NarrationSpeechRendering, job: NarrationCache.Job
    ) async throws -> TimeInterval {
        var retries = 0
        while true {
            try check(job)
            statusMessage = "Creating audio \(index + 1) of \(total)…"
            let output = try await cache.outputURL(segment: index, job: job)
            try check(job)
            do {
                let duration = try await renderer.render(text: text, voiceID: voiceID, to: output)
                try check(job)
                Self.log.debug("stage=rendering outcome=succeeded retries=\(retries, privacy: .public)")
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
            Self.log.info("stage=delete outcome=removed")
        } catch {
            if revision == started { errorMessage = "Narration could not be removed. Please try again." }
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
            if revision == started { errorMessage = "Some narration could not be removed. Please try again." }
            Self.log.error("stage=deleteAll outcome=failed")
        }
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
        defaults.set(min(position, limit), forKey: Self.positionPrefix + documentID)
    }

    func position(for documentID: String) -> TimeInterval {
        guard NarrationCache.isID(documentID) else { return 0 }
        let saved = defaults.double(forKey: Self.positionPrefix + documentID)
        guard saved.isFinite, saved >= 0 else { return 0 }
        return min(saved, ready[documentID]?.document.duration ?? saved)
    }

    /// The finished passages from the start, which can play before the full narration exists.
    func playablePrefix(of documentID: String) -> (document: NarrationDocument, segmentURLs: [URL])? {
        guard NarrationCache.isID(documentID), !deletingIDs.contains(documentID),
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
        guard let backgroundActivity else { return }
        let language = NarrationLanguageSupport.displayName(for: selection.targetLanguage)
        continuesInBackground = backgroundActivity.begin(
            title: "Translating into \(language)", subtitle: "Starting…",
            onExpire: { [weak self] in self?.backgroundExpired(job: job) }
        )
    }

    private func backgroundExpired(job: NarrationCache.Job) {
        continuesInBackground = false
        guard active?.job.id == job.id else { return }
        Self.log.notice("stage=background outcome=expired")
        cancel(job: job)
        statusMessage = "Preparation was stopped in the background. Completed passages are saved."
    }

    private func endRun(documentID: String, success: Bool) {
        backgroundActivity?.end(success: success)
        continuesInBackground = false
        estimator = nil
        estimatedSecondsRemaining = nil
        preparingDocumentID = nil
        onEvent?(.preparationEnded(documentID: documentID))
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
        endRun(documentID: preparation.documentID, success: false)
        Task { await cache.discardStaging(job: job) }
        // Retire the view's session promptly; a native lookahead may still be awaiting consent or a response.
        preparation.onFailure?(failure.underlying)
        Self.log.notice("stage=pipeline outcome=stopped reason=\(failure.stage.rawValue, privacy: .public)")
    }

    private func check(_ job: NarrationCache.Job) throws {
        try job.check()
        guard let preparation = active, preparation.job.id == job.id,
              preparation.owner == preparationOwner else { throw CancellationError() }
    }

    private func publish(_ snapshot: NarrationCache.Snapshot) {
        documents.removeAll { $0.id == snapshot.document.id }
        documents.append(snapshot.document)
        documents.sort(by: Self.mostRecent)
        ready[snapshot.document.id] = snapshot.document.isComplete ? snapshot : nil
        let expected = snapshot.document.expectedSegmentCount
        if snapshot.document.isComplete {
            progress = 1
        } else if let estimator, estimator.passageCount == expected {
            // The final share is reserved for joining passages into one file.
            progress = estimator.fraction * Double(expected) / Double(expected + 1)
        } else {
            progress = Double(snapshot.document.segments.count) / Double(expected + 1)
        }
        if active?.documentID == snapshot.document.id {
            completedPassages = snapshot.document.segments.count
            totalPassages = expected
            estimatedSecondsRemaining = snapshot.document.isComplete ? nil : estimator?.secondsRemaining
            if continuesInBackground, !snapshot.document.isComplete {
                var subtitle = NarrationTimeFormatting.passages(completedPassages, of: totalPassages)
                if let estimatedSecondsRemaining { subtitle += " · " + NarrationTimeFormatting.remaining(estimatedSecondsRemaining) }
                backgroundActivity?.update(fraction: progress, subtitle: subtitle)
            }
        }
        revision &+= 1
        onEvent?(.documentUpdated(snapshot.document))
    }

    private func forget(_ id: String) {
        documents.removeAll { $0.id == id }
        ready[id] = nil
        defaults.removeObject(forKey: Self.positionPrefix + id)
    }

    private static func mostRecent(_ lhs: NarrationDocument, _ rhs: NarrationDocument) -> Bool {
        lhs.updatedAt == rhs.updatedAt ? lhs.id < rhs.id : lhs.updatedAt > rhs.updatedAt
    }
}
