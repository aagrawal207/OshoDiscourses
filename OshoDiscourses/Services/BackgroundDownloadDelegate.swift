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
/// below is only ever touched there (hence `@unchecked Sendable`). Anything
/// that needs service state hops to the MainActor through the injected
/// callbacks; the one thing that MUST happen synchronously on the delegate
/// queue is moving the finished file, because iOS deletes the temp location
/// the moment `didFinishDownloadingTo` returns.
final class BackgroundDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    /// Callbacks into DownloadService, wired once at service init. Each hops to
    /// the MainActor internally. Keyed by discourse id (carried across process
    /// death in `taskDescription` — the only task field that survives relaunch).
    var onProgress: (@Sendable (_ discourseID: String, _ fraction: Double) -> Void)?
    var onFinished: (@Sendable (_ discourseID: String, _ stagedURL: URL) -> Void)?
    var onFailed: (@Sendable (_ discourseID: String, _ error: Error) -> Void)?

    /// Progress throttle: URLSession fires didWriteData very frequently, and
    /// every report spawns a MainActor hop. Only forward whole-percent changes.
    private var lastReportedFraction: [Int: Double] = [:]

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
        guard fraction - last >= 0.01 || fraction >= 1 else { return }
        lastReportedFraction[downloadTask.taskIdentifier] = fraction
        onProgress?(discourseID, fraction)
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
                onFailed?(discourseID, http.statusCode == 404
                    ? DownloadService.DownloadError.notFound
                    : DownloadService.DownloadError.serverError(http.statusCode))
                return
            }
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            if contentType.contains("text/html") {
                onFailed?(discourseID, DownloadService.DownloadError.notAudio)
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
            onFailed?(discourseID, DownloadService.saveError(from: error))
            return
        }
        onFinished?(discourseID, staged)
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
        onFailed?(discourseID, error)
    }

    // MARK: - Background relaunch handoff

    /// Fires after iOS relaunched the app to deliver queued download events and
    /// they've all been processed. Calling the stored completion handler tells
    /// the system we're done, so it can snapshot the app and suspend it again.
    /// Apple requires this to be called on the main thread.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            AppDelegate.backgroundSessionCompletionHandler?()
            AppDelegate.backgroundSessionCompletionHandler = nil
        }
    }
}
