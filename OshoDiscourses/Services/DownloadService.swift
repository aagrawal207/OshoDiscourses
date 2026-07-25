import Foundation
import Observation

@Observable
@MainActor
final class DownloadService {

    struct DownloadProgress {
        var progress: Double = 0
        var status: Status = .downloading

        enum Status {
            /// Requested but waiting its turn behind another transfer (downloads
            /// run one at a time so the active one gets the server's full speed).
            case queued
            case downloading
            case complete
            case failed(String)
        }

        /// True while this download is either transferring or waiting to — i.e.
        /// it occupies a slot and isn't finished or failed.
        var isActive: Bool {
            switch status {
            case .queued, .downloading: return true
            case .complete, .failed: return false
            }
        }
    }

    /// A download failure with a message the UI can show as-is. The raw system
    /// errors ("The operation couldn't be completed") tell the listener nothing,
    /// so every throw path maps to one of these plain-language reasons.
    enum DownloadError: LocalizedError {
        case wifiOnly
        case notFound
        case serverError(Int)
        case notAudio
        case offline
        case diskFull
        case saveFailed

        var errorDescription: String? {
            switch self {
            case .wifiOnly:  return "Wi-Fi only — turn on \"Download over Cellular\" in Settings."
            case .notFound:  return "Not available on the server (404)."
            case .serverError(let code): return "Server error (HTTP \(code))."
            case .notAudio:  return "Server returned a web page, not audio."
            case .offline:   return "No internet connection."
            case .diskFull:  return "Not enough storage on your device."
            case .saveFailed: return "Downloaded, but couldn't be saved. Try again."
            }
        }
    }

    /// Maps a raw file error to a short DownloadError so the UI never shows a
    /// long, truncatable Cocoa sentence ("… couldn't be moved to … because …").
    /// nonisolated: pure, and the background session's delegate queue needs it.
    nonisolated static func saveError(from error: Error) -> DownloadError {
        isOutOfSpace(error) ? .diskFull : .saveFailed
    }

    /// True if `error` — at any level of its underlying-error chain — means the
    /// disk is full. The out-of-space condition surfaces differently depending
    /// on which layer hits it first: Cocoa's NSFileWriteOutOfSpaceError from
    /// FileManager moves, or POSIX ENOSPC buried under a URLError when the
    /// URLSession task can't spool bytes to its temp file. Walking the chain
    /// catches all of them so the user sees "storage full", not gibberish.
    nonisolated static func isOutOfSpace(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let nsError = current {
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError {
                return true
            }
            if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC) {
                return true
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    var activeDownloads: [String: DownloadProgress] = [:]
    private(set) var downloadedIDs: Set<String> = []
    private var activeTasks: [String: URLSessionDownloadTask] = [:]

    /// One suspended continuation per in-flight transfer, resumed by the
    /// background session's delegate callbacks (staged file URL on success,
    /// error on failure). Replaces the completion-handler task: background
    /// sessions only speak delegate.
    private var transferContinuations: [String: CheckedContinuation<URL, Error>] = [:]

    /// The background session and its delegate. A background configuration
    /// hands transfers to the system's download daemon, so they keep going
    /// when the listener switches apps or locks the phone — with
    /// URLSession.shared the process suspended and the transfer died unless
    /// you stayed on the screen. `sessionSendsLaunchEvents` additionally
    /// relaunches the app to commit a file that finished after iOS killed us.
    private let sessionDelegate = BackgroundDownloadDelegate()
    // @ObservationIgnored: @Observable can't macro-transform a lazy stored
    // property, and session plumbing isn't UI state anyway.
    @ObservationIgnored private lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.background(
            withIdentifier: "com.agraabhi.oshodiscourses.background-downloads"
        )
        config.sessionSendsLaunchEvents = true
        // Start immediately — discretionary would let the system defer queued
        // talks for hours waiting for power + Wi-Fi.
        config.isDiscretionary = false
        // Overall per-transfer budget (default is 7 days). A 30 MB talk on a
        // slow connection is minutes; give it hours, not days, so a stuck
        // transfer eventually surfaces as a failure instead of a zombie row.
        config.timeoutIntervalForResource = 6 * 60 * 60
        return URLSession(configuration: config, delegate: sessionDelegate, delegateQueue: nil)
    }()

    /// IDs waiting their turn, in the order they were requested. Downloads start
    /// strictly front-to-back: a waiting item proceeds only when it's at the head
    /// AND no transfer is active. Without this explicit order, each queued task
    /// polled independently and whichever woke first when the slot freed would
    /// win — so 16,17,18,19 could start as 16,18,17,19.
    private var pendingQueue: [String] = []

    /// One suspended continuation per queued id. `advanceQueue()` resumes only
    /// the head-of-queue waiter when the transfer slot frees, so queued
    /// downloads wake exactly when it's their turn instead of polling every
    /// 200 ms. A cancel resumes the waiter throwing so its `download()` call
    /// unwinds immediately.
    private var queueWaiters: [String: CheckedContinuation<Void, Error>] = [:]

    // Maps discourse ID → relative path from Documents
    private var pathMap: [String: String] = [:]

    /// Every discourse ever downloaded, monotonic. Unlike `downloadedIDs` (which
    /// tracks only files currently on disk and shrinks on delete/eviction), this
    /// only grows, so a deleted discourse can be offered for quick re-download.
    /// Synced through iCloud so the list survives app deletion and new devices.
    private(set) var downloadHistory: Set<String> = []

    /// Fired when `downloadHistory` gains an entry, so the app can push it to iCloud.
    var onDownloadHistoryChanged: (() -> Void)?

    private let manifestURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent(".download_manifest.json")
    }()

    private let historyURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent(".download_history.json")
    }()

    init() {
        loadManifest()
        // Migration must run before loadHistory: it can add ids recovered from
        // the legacy flat downloads folder to `downloadedIDs`, and loadHistory
        // seeds history from that set. The old order left migrated ids out of
        // history for one full launch.
        migrateOldDownloads()
        loadHistory()
        excludeDownloadsFromBackup()
        consumeSessionEvents()
        // Touch the lazy session now: recreating a session with the same
        // identifier is what reattaches us to transfers that survived a
        // suspension — and, after a background relaunch, what makes the
        // pending didFinishDownloadingTo events flow so finished files get
        // committed instead of discarded.
        _ = backgroundSession
        adoptOrphanedTasks()
    }

    /// Consume the delegate's event stream in arrival order. FIFO matters:
    /// after a background relaunch, the finished-file events must be committed
    /// before `.backgroundEventsDrained` hands control back to iOS — with
    /// independent per-event hops, losing that race let the system re-suspend
    /// the app before the commit ran, stranding the downloaded file in tmp.
    private func consumeSessionEvents() {
        let stream = sessionDelegate.events
        Task { @MainActor [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .progress(let id, let taskID, let fraction):
                    // Only the CURRENT task for this id may move the row — a
                    // superseded (stall-restarted) task's late report must not
                    // overwrite the replacement's progress, and only a
                    // transferring row may move at all (a late report from a
                    // failed first attempt must not overwrite the retry's
                    // reset-to-zero, nor a completed row regress).
                    guard self.activeTasks[id]?.taskIdentifier == taskID else { break }
                    self.lastProgressAt[id] = Date()
                    if case .downloading = self.activeDownloads[id]?.status {
                        self.activeDownloads[id]?.progress = fraction
                    }
                case .finished(let id, _, let stagedURL):
                    // A finished file is accepted from ANY task generation —
                    // even one we were about to restart. transferFinished
                    // cancels whatever task is current for the id.
                    self.transferFinished(id: id, stagedURL: stagedURL)
                case .failed(let id, let taskID, let error):
                    self.transferFailed(id: id, taskID: taskID, error: error)
                case .backgroundEventsDrained:
                    AppDelegate.backgroundSessionCompletionHandler?()
                    AppDelegate.backgroundSessionCompletionHandler = nil
                }
            }
        }
    }

    /// Reattach to transfers that survived a process kill. Recreating the
    /// session resumes them in nsurlsessiond, but our in-memory bookkeeping
    /// (`activeTasks`/`activeDownloads`) starts empty — without adoption the
    /// UI shows nothing in flight, the user re-taps download, and the orphan's
    /// completion collides with the new attempt's continuation under the same
    /// discourse-id key (resuming it with the orphan's file while the new task
    /// becomes an uncancellable zombie).
    private func adoptOrphanedTasks() {
        backgroundSession.getAllTasks { [weak self] tasks in
            // getAllTasks calls back on the session's delegate queue.
            let downloads = tasks.compactMap { $0 as? URLSessionDownloadTask }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for task in downloads {
                    guard let id = task.taskDescription,
                          task.state == .running || task.state == .suspended else { continue }
                    // A row already tracked (e.g. download() re-queued before
                    // adoption ran) keeps its state; otherwise adopt.
                    if self.activeTasks[id] == nil {
                        self.activeTasks[id] = task
                        if self.activeDownloads[id] == nil {
                            self.activeDownloads[id] = DownloadProgress(status: .downloading)
                        }
                        // Watchdog coverage for adopted transfers too — they're
                        // the ones most likely to have gone stale across the
                        // relaunch.
                        self.lastProgressAt[id] = Date()
                    }
                }
                if !downloads.isEmpty { self.ensureWatchdogRunning() }
            }
        }
    }

    /// A transfer produced a staged file. Normally a `download()` call is
    /// suspended waiting for it; after a background relaunch there is no
    /// waiting call (the process that awaited died), so commit directly.
    private func transferFinished(id: String, stagedURL: URL) {
        // Whatever task is registered for this id is now moot: normally it IS
        // the finishing task (cancel is a no-op), but if a stall restart was
        // in flight it's the replacement — kill it so it doesn't download the
        // same bytes again. Deregister immediately so the cancelled
        // replacement's terminal event can't be mistaken for a real outcome.
        activeTasks[id]?.cancel()
        activeTasks.removeValue(forKey: id)
        clearStallTracking(id)
        if let continuation = transferContinuations.removeValue(forKey: id) {
            continuation.resume(returning: stagedURL)
            return
        }
        guard let lookup = Catalog.discourseLookup[id] else {
            try? FileManager.default.removeItem(at: stagedURL)
            return
        }
        // Adopted/relaunched transfer with no awaiting call: honor a cancel
        // that happened meanwhile (no activeDownloads row) by discarding.
        guard activeDownloads[id] != nil else {
            try? FileManager.default.removeItem(at: stagedURL)
            activeTasks.removeValue(forKey: id)
            return
        }
        do {
            _ = try commitDownload(lookup.discourse, from: stagedURL)
            activeDownloads[id] = DownloadProgress(progress: 1, status: .complete)
        } catch {
            activeDownloads[id] = DownloadProgress(status: .failed(error.localizedDescription))
        }
        activeTasks.removeValue(forKey: id)
    }

    private func transferFailed(id: String, taskID: Int, error: Error) {
        // A terminal event from a superseded task: the stall watchdog cancelled
        // it and (has installed / is installing) a replacement. While the
        // restart is mid-swap the id is marked in restartingIDs; after the
        // swap the identity check catches it. Either way the awaiting
        // download() keeps waiting for the replacement's outcome.
        if restartingIDs.contains(id) { return }
        if let current = activeTasks[id], current.taskIdentifier != taskID { return }

        clearStallTracking(id)
        if let continuation = transferContinuations.removeValue(forKey: id) {
            continuation.resume(throwing: error)
            return
        }
        // No awaiting call (adopted transfer, or a stale event from a task
        // that was deregistered). Only an actively-transferring row may be
        // touched — a late cancel must never clobber a completed row.
        activeTasks.removeValue(forKey: id)
        guard case .downloading = activeDownloads[id]?.status else { return }
        if (error as? URLError)?.code == .cancelled || error is CancellationError {
            activeDownloads.removeValue(forKey: id)
        } else {
            activeDownloads[id]?.status = .failed(error.localizedDescription)
        }
    }

    // MARK: - Stall Watchdog

    /// Background sessions never fail fast when connectivity changes: after a
    /// network switch the old connection to the (ephemeral) archive datanode
    /// can hang dead without erroring, and the transfer sits frozen until the
    /// 6-hour resource timeout. The watchdog notices a transfer that hasn't
    /// moved in `stallThreshold` and restarts it — with resume data when the
    /// server offers it, from scratch otherwise — up to `maxStallRestarts`
    /// times per attempt, keeping the same awaited continuation.
    nonisolated static let stallThreshold: TimeInterval = 120
    nonisolated static let maxStallRestarts = 2

    private var lastProgressAt: [String: Date] = [:]
    private var stallRestarts: [String: Int] = [:]
    /// The request each in-flight transfer was started with, for from-scratch
    /// restarts when no resume data is available.
    private var transferRequests: [String: URLRequest] = [:]
    /// Ids whose task is being swapped by the watchdog right now: terminal
    /// events for them are the old task dying, not a real outcome.
    private var restartingIDs: Set<String> = []
    private var watchdogTask: Task<Void, Never>?

    /// Pure stall rule, unit-testable: restart only when the transfer hasn't
    /// progressed within the threshold AND the restart budget isn't exhausted.
    nonisolated static func shouldRestartStalledTransfer(
        lastProgress: Date,
        now: Date,
        restartsSoFar: Int,
        threshold: TimeInterval = DownloadService.stallThreshold,
        maxRestarts: Int = DownloadService.maxStallRestarts
    ) -> Bool {
        restartsSoFar < maxRestarts && now.timeIntervalSince(lastProgress) >= threshold
    }

    private func ensureWatchdogRunning() {
        guard watchdogTask == nil else { return }
        watchdogTask = Task { @MainActor [weak self] in
            defer { self?.watchdogTask = nil }
            while let self, !self.activeTasks.isEmpty {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                self.checkForStalledTransfers()
            }
        }
    }

    private func checkForStalledTransfers() {
        let now = Date()
        for (id, task) in activeTasks where task.state == .running {
            guard case .downloading = activeDownloads[id]?.status,
                  !restartingIDs.contains(id),
                  let last = lastProgressAt[id],
                  Self.shouldRestartStalledTransfer(
                      lastProgress: last, now: now, restartsSoFar: stallRestarts[id] ?? 0
                  ) else { continue }
            restartStalledTransfer(id: id)
        }
    }

    private func restartStalledTransfer(id: String) {
        guard let stalled = activeTasks[id] else { return }
        stallRestarts[id, default: 0] += 1
        // Mark BEFORE cancelling: the old task's .cancelled event can arrive
        // before the resume-data completion runs, and it must not be taken
        // for the transfer's real outcome.
        restartingIDs.insert(id)
        print("[Downloads] transfer for \(id) stalled; restarting (attempt \(stallRestarts[id] ?? 0))")
        stalled.cancel { [weak self] resumeData in
            // Completion arrives off-main; the data is Sendable.
            Task { @MainActor [weak self] in
                self?.installReplacementTask(id: id, resumeData: resumeData)
            }
        }
    }

    private func installReplacementTask(id: String, resumeData: Data?) {
        defer { restartingIDs.remove(id) }
        // The transfer may have concluded in the cancel window (file finished
        // and resumed the continuation, or the user cancelled the download) —
        // nothing left to replace.
        guard transferContinuations[id] != nil, activeDownloads[id] != nil else { return }
        let task: URLSessionDownloadTask
        if let resumeData {
            task = backgroundSession.downloadTask(withResumeData: resumeData)
        } else if let request = transferRequests[id] {
            task = backgroundSession.downloadTask(with: request)
        } else {
            return
        }
        task.taskDescription = id
        activeTasks[id] = task
        lastProgressAt[id] = Date()
        task.resume()
    }

    private func clearStallTracking(_ id: String) {
        lastProgressAt.removeValue(forKey: id)
        stallRestarts.removeValue(forKey: id)
        transferRequests.removeValue(forKey: id)
        restartingIDs.remove(id)
    }

    // MARK: - Public

    func download(_ discourse: CatalogDiscourse) async throws -> URL {
        let destination = fileURL(for: discourse)

        if FileManager.default.fileExists(atPath: destination.path) {
            downloadedIDs.insert(discourse.id)
            pathMap[discourse.id] = relativePath(for: discourse)
            saveManifest()
            recordDownloaded(discourse.id)
            activeDownloads[discourse.id] = DownloadProgress(progress: 1, status: .complete)
            return destination
        }

        // Ignore a duplicate request for something already in flight or waiting.
        if let existing = activeDownloads[discourse.id] {
            switch existing.status {
            case .downloading, .queued: return destination
            default: break
            }
        }
        // Likewise for an adopted orphan transfer (survived a process kill and
        // was re-attached by adoptOrphanedTasks): a second session task under
        // the same id would collide with its completion event.
        if activeTasks[discourse.id] != nil {
            return destination
        }

        // One transfer at a time, first-come-first-served. Join the tail of the
        // queue and suspend until we're at its head with no transfer active — so
        // the running download keeps the server's full bandwidth and the rest
        // start in request order (16 → 17 → 18 → 19). Show a queued state
        // meanwhile so the row reads as "waiting", not "not started". Everything
        // here runs on @MainActor and the continuation body executes before the
        // suspension (SE-0420 isolation inheritance), so nothing can interleave
        // between the eligibility check and registering the waiter — exactly one
        // queued item advances at a time.
        activeDownloads[discourse.id] = DownloadProgress(status: .queued)
        pendingQueue.append(discourse.id)
        if pendingQueue.first != discourse.id || isAnyTransferActive(excluding: discourse.id) {
            do {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        queueWaiters[discourse.id] = continuation
                        // Belt-and-braces: if the slot freed in the instant
                        // before this waiter registered, the nudge already
                        // happened — re-run it now so we can't sleep forever.
                        advanceQueue()
                    }
                } onCancel: {
                    // Structured cancellation of the owning Task (distinct from
                    // cancelDownload). Runs off-actor, so hop back before
                    // touching state.
                    Task { @MainActor [weak self] in self?.failQueueWaiter(discourse.id) }
                }
            } catch {
                // Cancelled while waiting — leave no trace, and nudge the queue
                // in case we were the head blocking the next item.
                pendingQueue.removeAll { $0 == discourse.id }
                activeDownloads.removeValue(forKey: discourse.id)
                advanceQueue()
                throw CancellationError()
            }
            // Resumed normally, but cancelDownload may have run between the
            // resume being scheduled and this line executing — bail like the
            // old poll's activeDownloads check did.
            if activeDownloads[discourse.id] == nil || Task.isCancelled {
                pendingQueue.removeAll { $0 == discourse.id }
                activeDownloads.removeValue(forKey: discourse.id)
                advanceQueue()
                throw CancellationError()
            }
        }

        pendingQueue.removeAll { $0 == discourse.id }
        // The file may have appeared while we waited in the queue (an adopted
        // background transfer committed it, or a Download All overlap) — don't
        // re-download identical bytes.
        if FileManager.default.fileExists(atPath: destination.path) {
            downloadedIDs.insert(discourse.id)
            pathMap[discourse.id] = relativePath(for: discourse)
            saveManifest()
            recordDownloaded(discourse.id)
            activeDownloads[discourse.id] = DownloadProgress(progress: 1, status: .complete)
            return destination
        }
        activeDownloads[discourse.id] = DownloadProgress(status: .downloading)
        // However this download ends — success, failure, or cancellation — the
        // transfer slot frees, so wake whoever is next in line.
        defer { advanceQueue() }

        do {
            // Prefer the Archive.org mirror (~12x faster than oshoworld.com in
            // measurement); fall back to oshoworld for the ~10% of discourses
            // not mirrored, or if the archive attempt fails server-side.
            let sources = downloadSources(for: discourse)
            guard !sources.isEmpty else { throw URLError(.badURL) }

            var localURL: URL?
            for (index, url) in sources.enumerated() {
                // A cancel can land in the gap between one attempt failing and
                // the next starting (its continuation resumes in an earlier
                // MainActor job than our catch block). Starting the fallback
                // anyway would run an invisible, unstoppable transfer alongside
                // whatever download the freed slot just woke.
                if activeDownloads[discourse.id] == nil || Task.isCancelled {
                    throw CancellationError()
                }
                do {
                    localURL = try await downloadWithProgress(url: url, discourseID: discourse.id)
                    break
                } catch {
                    let isLast = index == sources.count - 1
                    guard !isLast, Self.shouldTryNextSource(after: error) else { throw error }
                    // Retrying from another host: rewind the progress ring so it
                    // doesn't sit at a stale percentage from the failed attempt.
                    activeDownloads[discourse.id]?.progress = 0
                }
            }
            guard let localURL else { throw URLError(.unknown) }

            // Cancel race: cancelDownload clears our activeDownloads row
            // synchronously, but if the transfer had already finished, the
            // URLSession cancel is a no-op and we land here holding a complete
            // file. Honor the cancel — discard the bytes instead of committing
            // a download the listener asked to stop.
            if activeDownloads[discourse.id] == nil || Task.isCancelled {
                try? FileManager.default.removeItem(at: localURL)
                throw CancellationError()
            }

            // Filesystem steps throw long Cocoa sentences; commitDownload maps
            // them to short messages so the UI row shows a clean reason instead
            // of a truncated "…couldn't be moved to…because…".
            let savedURL = try commitDownload(discourse, from: localURL)
            activeDownloads[discourse.id]?.status = .complete
            activeDownloads[discourse.id]?.progress = 1
            return savedURL
        } catch {
            // Cancellation isn't a failure the row should display — drop the
            // entry entirely (matching cancelDownload) instead of showing
            // "operation cancelled" as an error the user has to dismiss.
            if error is CancellationError {
                activeDownloads.removeValue(forKey: discourse.id)
            } else {
                activeDownloads[discourse.id]?.status = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    /// Move a finished transfer's staged file into the library and record it.
    /// Shared by the normal `download()` path and the background-relaunch path
    /// (file finished after iOS killed the process). moveItem refuses to
    /// overwrite, so any stray file at the destination is cleared first — the
    /// fresh download is authoritative.
    private func commitDownload(_ discourse: CatalogDiscourse, from stagedURL: URL) throws -> URL {
        let destination = fileURL(for: discourse)
        let seriesDir = destination.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: seriesDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: stagedURL, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: stagedURL)
            throw Self.saveError(from: error)
        }
        // Exclude the new file and its series folder from backup individually —
        // the flag isn't inherited from the root on iOS (see
        // excludeDownloadsFromBackup).
        setExcludedFromBackup(seriesDir)
        setExcludedFromBackup(destination)
        downloadedIDs.insert(discourse.id)
        pathMap[discourse.id] = relativePath(for: discourse)
        saveManifest()
        recordDownloaded(discourse.id)
        return destination
    }

    /// Fire-and-forget download for UI call sites. Owns the Task, clears a
    /// previous failed state so retry works, and swallows the error — the row
    /// UI reads failure state from `activeDownloads`, so throwing to the view
    /// adds nothing. Replaces the `Task { _ = try? await ... }` pattern that
    /// was copy-pasted across six views.
    func startDownload(_ discourse: CatalogDiscourse) {
        if case .failed = activeDownloads[discourse.id]?.status {
            activeDownloads[discourse.id] = nil
        }
        Task { _ = try? await download(discourse) }
    }

    func deleteDownload(discourseID: String) throws {
        if let url = localFileURL(for: discourseID) {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            // Remove empty series folder
            let parent = url.deletingLastPathComponent()
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: parent.path), contents.isEmpty {
                try? FileManager.default.removeItem(at: parent)
            }
        }
        downloadedIDs.remove(discourseID)
        pathMap.removeValue(forKey: discourseID)
        saveManifest()
        activeDownloads.removeValue(forKey: discourseID)
    }

    /// Delete a specific set of downloaded discourses (multi-select / per-series).
    func deleteDownloads(ids: [String]) {
        for id in ids {
            try? deleteDownload(discourseID: id)
        }
    }

    /// Delete every downloaded discourse. Iterates a snapshot since
    /// `deleteDownload` mutates `downloadedIDs` as it goes.
    func deleteAllDownloads() {
        for id in Array(downloadedIDs) {
            try? deleteDownload(discourseID: id)
        }
    }

    func isDownloaded(_ discourseID: String) -> Bool {
        downloadedIDs.contains(discourseID)
    }

    /// True while a download is transferring OR waiting in the queue — both are
    /// "in progress" as far as the row's cancel/progress control is concerned.
    func isDownloading(_ discourseID: String) -> Bool {
        activeDownloads[discourseID]?.isActive ?? false
    }

    /// True only while waiting its turn behind another transfer. The UI uses this
    /// to show "Queued" instead of a 0% progress ring that isn't moving yet.
    func isQueued(_ discourseID: String) -> Bool {
        guard let dl = activeDownloads[discourseID] else { return false }
        if case .queued = dl.status { return true }
        return false
    }

    /// IDs currently transferring or queued, ordered for display: the active
    /// transfer first, then the queued ones in the order they'll run. Membership
    /// comes from live status in `activeDownloads`; `pendingQueue` supplies the
    /// order (any queued id somehow not in it falls to the end). Lets "My
    /// Activity" show in-progress downloads, not just the series page.
    func inProgressIDs() -> [String] {
        let transferring = activeDownloads.compactMap { id, dl -> String? in
            if case .downloading = dl.status { return id }
            return nil
        }
        let queued = activeDownloads.compactMap { id, dl -> String? in
            if case .queued = dl.status { return id }
            return nil
        }
        let ordered = queued.sorted {
            (pendingQueue.firstIndex(of: $0) ?? .max) < (pendingQueue.firstIndex(of: $1) ?? .max)
        }
        return transferring + ordered
    }

    /// Whether any discourse other than `id` is actively transferring (not merely
    /// queued). Gates the one-at-a-time queue so waiting downloads only block on
    /// the running one, never on each other.
    private func isAnyTransferActive(excluding id: String) -> Bool {
        activeDownloads.contains { key, value in
            guard key != id else { return false }
            if case .downloading = value.status { return true }
            return false
        }
    }

    /// Wake the next queued download if the transfer slot is free. Resumes at
    /// most the head-of-queue waiter, keeping order strictly FIFO: the resumed
    /// task claims the slot by flipping to `.downloading` before any later
    /// waiter can be resumed. Idempotent — a head already resumed (but not yet
    /// running) has no waiter registered, so a second call is a no-op rather
    /// than a double-start.
    private func advanceQueue() {
        guard !isAnyTransferActive(excluding: "") else { return }
        guard let head = pendingQueue.first,
              let continuation = queueWaiters.removeValue(forKey: head) else { return }
        continuation.resume()
    }

    /// Unwind a queued download's suspended `download()` call with a
    /// CancellationError. Safe to call for ids with no waiter (already resumed,
    /// or never queued) — the dictionary removal doubles as the resume-once guard.
    private func failQueueWaiter(_ id: String) {
        guard let continuation = queueWaiters.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CancellationError())
    }

    func cancelDownload(discourseID: String) {
        activeTasks[discourseID]?.cancel()
        activeTasks.removeValue(forKey: discourseID)
        // Unwind the awaiting download() directly instead of relying on the
        // task's .cancelled delegate event: during a watchdog restart the old
        // task's terminal events are deliberately suppressed, and depending on
        // them here would leave the continuation parked forever.
        if let continuation = transferContinuations.removeValue(forKey: discourseID) {
            continuation.resume(throwing: CancellationError())
        }
        clearStallTracking(discourseID)
        pendingQueue.removeAll { $0 == discourseID }
        activeDownloads.removeValue(forKey: discourseID)
        // A queued download is parked on a continuation, not a network task —
        // resume it throwing so its download() call unwinds now instead of
        // waiting for its turn only to bail.
        failQueueWaiter(discourseID)
        // Removing the head of the queue (or the active transfer) may free the
        // slot for whoever is next.
        advanceQueue()
    }

    func progress(for discourseID: String) -> Double {
        activeDownloads[discourseID]?.progress ?? 0
    }

    func localFileURL(for discourseID: String) -> URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

        if let rel = pathMap[discourseID] {
            let url = docs.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            // File missing on disk — evict from manifest
            downloadedIDs.remove(discourseID)
            pathMap.removeValue(forKey: discourseID)
            saveManifest()
            return nil
        }

        // Fallback: old flat path
        let oldPath = docs.appendingPathComponent("downloads/\(discourseID).mp3")
        if FileManager.default.fileExists(atPath: oldPath.path) {
            return oldPath
        }

        return nil
    }

    /// Actual on-disk size (bytes) of each downloaded discourse, keyed by ID.
    /// Sums per-file allocated bytes — not the static ~20/30 MB estimate. Stats
    /// the files off the main actor so a large library doesn't hitch the UI.
    /// The view derives both per-series and total sizes from this one map.
    func downloadedSizes() async -> [String: Int64] {
        // Snapshot id→url on the main actor (localFileURL can mutate state).
        var urls: [String: URL] = [:]
        for id in Array(downloadedIDs) {
            if let url = localFileURL(for: id) { urls[id] = url }
        }
        return await Task.detached(priority: .utility) {
            var sizes: [String: Int64] = [:]
            for (id, url) in urls {
                let values = try? url.resourceValues(
                    forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
                )
                sizes[id] = Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
            }
            return sizes
        }.value
    }

    func downloadedDiscourses() -> [(seriesInfo: SeriesInfo, discourses: [CatalogDiscourse])] {
        var groups: [String: (seriesInfo: SeriesInfo, discourses: [CatalogDiscourse])] = [:]

        for series in Catalog.allSeries {
            let downloaded = Catalog.discourses(for: series).filter { downloadedIDs.contains($0.id) }
            if !downloaded.isEmpty {
                groups[series.id] = (seriesInfo: series, discourses: downloaded)
            }
        }

        return groups.values.sorted { $0.seriesInfo.name < $1.seriesInfo.name }
    }

    // MARK: - File Paths

    private let rootFolderName = "Osho Discourses"

    private func downloadsRootURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(rootFolderName)
    }

    /// Marks the downloads folder — and everything already inside it — as excluded
    /// from iCloud/iTunes backup. The discourses are re-downloadable from
    /// oshoworld.com, so backing them up would bloat the user's iCloud storage —
    /// and Apple rejects apps that back up re-creatable bulk data (App Store
    /// guideline 5.1 / Data Storage).
    ///
    /// `isExcludedFromBackup` is per-URL on iOS; it is NOT inherited by files
    /// created later inside an excluded directory. So we exclude the root here for
    /// existing files (a one-time pass at launch that covers anyone upgrading from
    /// a build that only flagged the root), and each new file + its series folder
    /// get flagged individually right after they're written (see download(_:)).
    private func excludeDownloadsFromBackup() {
        let root = downloadsRootURL()
        // Create the folder if it doesn't exist yet so the flag has somewhere to
        // live before the first download writes into it.
        if !FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        setExcludedFromBackup(root)
        // One-time launch sweep over existing content. Cheap: setResourceValues is
        // idempotent, and a fully-downloaded library is a few thousand files at
        // most. Runs off the main actor so a large library doesn't hitch launch.
        let rootPath = root.path
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: rootPath), includingPropertiesForKeys: nil) else { return }
            // allObjects snapshots the walk into an array — NSEnumerator's lazy
            // iterator isn't usable from an async context.
            for case let fileURL as URL in enumerator.allObjects {
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                var mutableURL = fileURL
                try? mutableURL.setResourceValues(values)
            }
        }
    }

    private func setExcludedFromBackup(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        do {
            try mutableURL.setResourceValues(values)
        } catch {
            print("[Downloads] failed to exclude from backup: \(error)")
        }
    }

    private func fileURL(for discourse: CatalogDiscourse) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(relativePath(for: discourse))
    }

    private func relativePath(for discourse: CatalogDiscourse) -> String {
        let safeSeries = discourse.seriesName.replacingOccurrences(of: "/", with: "-")
        let safeTitle = "\(safeSeries) - #\(discourse.number).mp3"
        return "\(rootFolderName)/\(safeSeries)/\(safeTitle)"
    }

    // MARK: - Manifest

    private func saveManifest() {
        guard let data = try? JSONEncoder().encode(pathMap) else { return }
        let dir = manifestURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            // .atomic writes to a temp file then renames, so a crash or full
            // disk mid-write can never leave a truncated manifest behind — a
            // corrupt manifest would silently orphan the whole library.
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            print("[Downloads] failed to save manifest: \(error)")
        }
    }

    private func loadManifest() {
        // Also try migrating from old Documents location
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let oldManifestURL = docs.appendingPathComponent(".download_manifest.json")
        let sourceURL: URL
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            sourceURL = manifestURL
        } else if FileManager.default.fileExists(atPath: oldManifestURL.path) {
            sourceURL = oldManifestURL
            // Remove old manifest after migration
            try? FileManager.default.removeItem(at: oldManifestURL)
        } else {
            return
        }

        guard let data = try? Data(contentsOf: sourceURL),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        pathMap = map
        // Trust manifest at load time; lazily verify in localFileURL(for:)
        downloadedIDs = Set(map.keys)
    }

    // MARK: - Download History (persistent, iCloud-synced)

    /// Add an id to the ever-downloaded history. No-op if already present; on a
    /// genuine addition it persists and notifies so the change reaches iCloud.
    private func recordDownloaded(_ id: String) {
        guard downloadHistory.insert(id).inserted else { return }
        saveHistory()
        onDownloadHistoryChanged?()
    }

    /// Union in ids from another device. Returns true if anything was added, so
    /// the caller knows whether local state changed. Monotonic: never removes.
    @discardableResult
    func mergeSyncedDownloadHistory(_ incoming: [String]) -> Bool {
        let before = downloadHistory.count
        downloadHistory.formUnion(incoming)
        guard downloadHistory.count != before else { return false }
        saveHistory()
        return true
    }

    /// Drop ids from the "previously downloaded" history so the user can dismiss
    /// entries they don't want offered for re-download. Persists and pushes the
    /// smaller set to iCloud. No tombstones: as with bookmark deletes, a second
    /// device that still has an id can resurrect it on the next sync — acceptable
    /// for a convenience list. Anything currently on disk stays in history (it'd
    /// only be re-seeded on next launch anyway), so we ignore those.
    func forgetDownloadHistory(ids: [String]) {
        let removable = ids.filter { !downloadedIDs.contains($0) }
        let before = downloadHistory.count
        downloadHistory.subtract(removable)
        guard downloadHistory.count != before else { return }
        saveHistory()
        onDownloadHistoryChanged?()
    }

    /// The history as a plain array for the cloud snapshot.
    func syncedDownloadHistory() -> [String] { Array(downloadHistory) }

    private func saveHistory() {
        guard let data = try? JSONEncoder().encode(Array(downloadHistory)) else { return }
        let dir = historyURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            // .atomic for the same reason as saveManifest: a torn write would
            // lose the ever-downloaded history until the next iCloud merge.
            try data.write(to: historyURL, options: .atomic)
        } catch {
            print("[Downloads] failed to save history: \(error)")
        }
    }

    private func loadHistory() {
        if let data = try? Data(contentsOf: historyURL),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            downloadHistory = Set(ids)
        }
        // Anything already on disk is by definition part of the history — seed it
        // so existing users' current downloads enter history on first launch of
        // this version (loadManifest and migrateOldDownloads both run before
        // loadHistory, so migrated legacy files are seeded too). Persist the seed
        // so a later delete-then-restart can't lose an id that was never written.
        let before = downloadHistory.count
        downloadHistory.formUnion(downloadedIDs)
        if downloadHistory.count != before { saveHistory() }
    }

    // MARK: - Migration

    private func migrateOldDownloads() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let oldDir = docs.appendingPathComponent("downloads")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: oldDir.path) else { return }

        for file in files where file.hasSuffix(".mp3") {
            let id = String(file.dropLast(4))
            if !downloadedIDs.contains(id) {
                downloadedIDs.insert(id)
                // Keep old path in manifest for now; will be moved on next download or kept as-is
                pathMap[id] = "downloads/\(file)"
            }
        }
        if !files.isEmpty { saveManifest() }
    }

    // MARK: - Networking

    /// Download URLs to try, in order: the Archive.org mirror first (when the
    /// discourse is mapped there), then the original oshoworld.com URL.
    private func downloadSources(for discourse: CatalogDiscourse) -> [URL] {
        var urls: [URL] = []
        if let archive = ArchiveCatalog.audioURL(for: discourse) {
            urls.append(archive)
        }
        if let osho = try? encodedURL(from: discourse.audioURL) {
            urls.append(osho)
        }
        return urls
    }

    /// Whether a failure from one source justifies trying the next one.
    /// Server-side problems (missing file, error status, HTML instead of
    /// audio) and transport flakiness are worth a retry from the other host;
    /// conditions local to the device (no internet, cellular gate, full disk)
    /// or an explicit cancel would fail identically and must surface as-is.
    nonisolated static func shouldTryNextSource(after error: Error) -> Bool {
        if error is CancellationError { return false }
        if let dl = error as? DownloadError {
            switch dl {
            case .notFound, .serverError, .notAudio: return true
            case .wifiOnly, .offline, .diskFull, .saveFailed: return false
            }
        }
        return true  // timeouts, connection resets, and other transport errors
    }

    private func encodedURL(from rawURL: String) throws -> URL {
        guard let url = URL(string: rawURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? rawURL) else {
            throw URLError(.badURL)
        }
        return url
    }

    private func downloadWithProgress(url: URL, discourseID: String) async throws -> URL {
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        // Per-request cellular gate. The toggle lives in Settings → Player &
        // Downloads and defaults off. Note the background-session semantics:
        // on cellular with the gate closed, the system *waits* for Wi-Fi
        // rather than failing fast (bounded by timeoutIntervalForResource).
        request.allowsCellularAccess = UserSettings.shared.allowCellularDownloads

        // Whether the transfer completes, throws, or is cancelled, drop the
        // task handle and stall-tracking for this id so nothing leaks.
        defer {
            activeTasks.removeValue(forKey: discourseID)
            clearStallTracking(discourseID)
        }

        // The transfer runs on the background session so it survives app
        // switches, the lock screen, and even process death (see
        // BackgroundDownloadDelegate). The delegate resumes this continuation
        // with the staged file (already moved out of the system temp location)
        // or the transport error; response validation (404 / HTML-not-audio)
        // also happens in the delegate, before staging.
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    transferContinuations[discourseID] = continuation
                    let task = backgroundSession.downloadTask(with: request)
                    // taskDescription is the one field that survives process
                    // death with the task — it's how a relaunch knows which
                    // discourse a finished file belongs to.
                    task.taskDescription = discourseID
                    activeTasks[discourseID] = task
                    // Arm the stall watchdog: a network change can leave the
                    // connection hanging dead without an error, and only the
                    // watchdog gets it moving again.
                    transferRequests[discourseID] = request
                    lastProgressAt[discourseID] = Date()
                    stallRestarts[discourseID] = 0
                    ensureWatchdogRunning()
                    task.resume()
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.activeTasks[discourseID]?.cancel() }
            }
        } catch let error as URLError {
            // Translate the transport failures the listener can actually act
            // on. Everything else keeps its description.
            switch error.code {
            // Task.cancel() surfaces as URLError.cancelled, not Swift's
            // CancellationError — normalize so callers treat both alike
            // (drop the row, don't show "cancelled" as a failure).
            case .cancelled: throw CancellationError()
            case .dataNotAllowed: throw DownloadError.wifiOnly   // cellular gate blocked it
            case .notConnectedToInternet, .networkConnectionLost: throw DownloadError.offline
            // The session spools to a temp file as bytes arrive, so a full disk
            // shows up here as a write failure, not later at the move step.
            case .cannotWriteToFile: throw DownloadError.diskFull
            default:
                if Self.isOutOfSpace(error) { throw DownloadError.diskFull }
                throw error
            }
        }
    }
}
