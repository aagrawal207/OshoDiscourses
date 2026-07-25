import Foundation

/// URLSessionDownloadDelegate for the background download session.
///
/// Why a background session at all: `URLSession.shared` transfers run inside
/// our process, so the moment the listener switched apps or locked the phone
/// the process suspended and the download died — you had to sit on the screen
/// until it finished. A background session hands the transfer to the system's
/// download daemon (nsurlsessiond), which keeps going while the app is
/// suspended and even relaunches the app when the file lands after iOS killed
/// the process.
///
/// Threading model: the session is created with `delegateQueue: nil`, so all
/// callbacks arrive on one serial OperationQueue — the mutable throttle state
/// below is only ever touched there (hence `@unchecked Sendable`). The one
/// thing that MUST happen synchronously on the delegate queue is moving the
/// finished file, because iOS deletes the temp location the moment
/// `didFinishDownloadingTo` returns. Everything else flows to DownloadService
/// through a single AsyncStream.
final class BackgroundDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    /// Everything the delegate observes, in exact arrival order.
    ///
    /// One FIFO AsyncStream (consumed by DownloadService on the MainActor)
    /// instead of independent `Task { @MainActor }` hops per callback: with
    /// independent hops, the relative order of "commit this finished file"
    /// and "all background events drained, tell iOS we're done" was only
    /// best-effort — losing that race after a background relaunch would let
    /// iOS re-suspend (and later kill) the app before the commit ran,
    /// stranding a fully-downloaded file in tmp. A stream makes the ordering
    /// deterministic: commits are handled before the drain event.
    enum Event: Sendable {
        // taskID lets the service ignore terminal events from a superseded
        // task: the stall watchdog cancels and replaces hung transfers under
        // the same discourse id, and the old task's dying gasp must not be
        // mistaken for the replacement's outcome.
        case progress(discourseID: String, taskID: Int, fraction: Double)
        case finished(discourseID: String, taskID: Int, stagedURL: URL)
        case failed(discourseID: String, taskID: Int, error: any Error)
        /// All queued events after a background relaunch have been delivered;
        /// the app-provided completion handler may now be called.
        case backgroundEventsDrained
    }

    let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    /// Progress throttle: URLSession fires didWriteData very frequently, and
    /// every event costs a MainActor hop. Only forward whole-percent changes.
    private var lastReportedFraction: [Int: Double] = [:]

    override init() {
        (events, continuation) = AsyncStream.makeStream(of: Event.self)
        super.init()
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let discourseID = downloadTask.taskDescription,
              totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let last = lastReportedFraction[downloadTask.taskIdentifier] ?? 0
        // Report increases of >=1%, completion, AND regressions: after a
        // network change the system can restart the transfer from byte 0, and
        // an increase-only throttle froze the ring at the old percentage even
        // though bytes were flowing again.
        guard fraction - last >= 0.01 || fraction >= 1 || fraction < last else { return }
        lastReportedFraction[downloadTask.taskIdentifier] = fraction
        continuation.yield(.progress(discourseID: discourseID, taskID: downloadTask.taskIdentifier, fraction: fraction))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lastReportedFraction.removeValue(forKey: downloadTask.taskIdentifier)
        guard let discourseID = downloadTask.taskDescription else { return }

        // Validate the response before staging — the server returns 200 HTML
        // error pages and 404s that must not be saved as "audio".
        if let http = downloadTask.response as? HTTPURLResponse {
            guard (200...299).contains(http.statusCode) else {
                continuation.yield(.failed(discourseID: discourseID, taskID: downloadTask.taskIdentifier, error: http.statusCode == 404
                    ? DownloadService.DownloadError.notFound
                    : DownloadService.DownloadError.serverError(http.statusCode)))
                return
            }
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            if contentType.contains("text/html") {
                continuation.yield(.failed(discourseID: discourseID, taskID: downloadTask.taskIdentifier, error: DownloadService.DownloadError.notAudio))
                return
            }
        }

        // iOS deletes `location` when this method returns — move it to a stable
        // spot NOW, synchronously, before handing off to the MainActor.
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mp3")
        do {
            try FileManager.default.moveItem(at: location, to: staged)
        } catch {
            continuation.yield(.failed(discourseID: discourseID, taskID: downloadTask.taskIdentifier, error: DownloadService.saveError(from: error)))
            return
        }
        continuation.yield(.finished(discourseID: discourseID, taskID: downloadTask.taskIdentifier, stagedURL: staged))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lastReportedFraction.removeValue(forKey: task.taskIdentifier)
        // Success is reported by didFinishDownloadingTo; this callback only
        // matters for transport-level failure (didFinish never fires then).
        guard let error, let discourseID = task.taskDescription else { return }
        continuation.yield(.failed(discourseID: discourseID, taskID: task.taskIdentifier, error: error))
    }

    /// Fires after iOS relaunched the app to deliver queued download events
    /// and they've all been delivered. Because this yields into the same FIFO
    /// stream as the finished-file events above, DownloadService is guaranteed
    /// to commit those files before it calls the stored completion handler.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        continuation.yield(.backgroundEventsDrained)
    }
}
