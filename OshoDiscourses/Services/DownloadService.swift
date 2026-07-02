import Foundation
import Observation

@Observable
@MainActor
final class DownloadService {

    struct DownloadProgress {
        var progress: Double = 0
        var status: Status = .downloading

        enum Status {
            case downloading
            case complete
            case failed(String)
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
    private static func saveError(from error: Error) -> DownloadError {
        (error as NSError).code == NSFileWriteOutOfSpaceError ? .diskFull : .saveFailed
    }

    var activeDownloads: [String: DownloadProgress] = [:]
    private(set) var downloadedIDs: Set<String> = []
    private var activeTasks: [String: URLSessionDownloadTask] = [:]

    // Maps discourse ID → relative path from Documents
    private var pathMap: [String: String] = [:]

    /// Every discourse ever downloaded, monotonic. Unlike `downloadedIDs` (which
    /// tracks only files currently on disk and shrinks on delete/eviction), this
    /// only grows, so a deleted discourse can be offered for quick re-download.
    /// Synced through iCloud so the list survives app deletion and new devices.
    private(set) var downloadHistory: Set<String> = []

    /// Fired when `downloadHistory` gains an entry, so the app can push it to iCloud.
    var onDownloadHistoryChanged: (() -> Void)?

    private let maxConcurrent = 3

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
        loadHistory()
        migrateOldDownloads()
        excludeDownloadsFromBackup()
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

        // Prevent concurrent downloads of the same discourse
        if let existing = activeDownloads[discourse.id], case .downloading = existing.status {
            return destination
        }

        // Limit concurrent downloads
        while activeDownloads.values.filter({ if case .downloading = $0.status { return true } else { return false } }).count >= maxConcurrent {
            try await Task.sleep(for: .milliseconds(500))
        }

        activeDownloads[discourse.id] = DownloadProgress()

        do {
            let url = try encodedURL(from: discourse.audioURL)

            // Ensure series folder exists
            let seriesDir = destination.deletingLastPathComponent()

            let localURL = try await downloadWithProgress(url: url, discourseID: discourse.id)

            // Filesystem steps throw long Cocoa sentences; map them to short
            // messages so the UI row shows a clean reason instead of a truncated
            // "…couldn't be moved to…because…". moveItem also refuses to
            // overwrite, so clear any stray file at the destination first (a
            // duplicate request that slipped past the guard above, or a leftover
            // from an interrupted move) — the fresh download is authoritative.
            do {
                try FileManager.default.createDirectory(at: seriesDir, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try? FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: localURL, to: destination)
            } catch {
                try? FileManager.default.removeItem(at: localURL)
                throw Self.saveError(from: error)
            }
            downloadedIDs.insert(discourse.id)
            pathMap[discourse.id] = relativePath(for: discourse)
            saveManifest()
            recordDownloaded(discourse.id)
            activeDownloads[discourse.id]?.status = .complete
            activeDownloads[discourse.id]?.progress = 1
            return destination
        } catch {
            activeDownloads[discourse.id]?.status = .failed(error.localizedDescription)
            throw error
        }
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

    func isDownloading(_ discourseID: String) -> Bool {
        guard let dl = activeDownloads[discourseID] else { return false }
        if case .downloading = dl.status { return true }
        return false
    }

    func cancelDownload(discourseID: String) {
        activeTasks[discourseID]?.cancel()
        activeTasks.removeValue(forKey: discourseID)
        activeDownloads.removeValue(forKey: discourseID)
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

    /// Marks the downloads folder as excluded from iCloud/iTunes backup. The
    /// discourses are re-downloadable from oshoworld.com, so backing them up
    /// would bloat the user's iCloud storage — and Apple rejects apps that back
    /// up re-creatable bulk data (App Store guideline 5.1 / Data Storage).
    /// The flag is inherited by files created inside the folder, so setting it on
    /// the directory covers everything. Idempotent and cheap; safe to call often.
    private func excludeDownloadsFromBackup() {
        let root = downloadsRootURL()
        // Create the folder if it doesn't exist yet so the flag has somewhere to
        // live before the first download writes into it.
        if !FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        setExcludedFromBackup(root)
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
        try? data.write(to: manifestURL)
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

    /// The history as a plain array for the cloud snapshot.
    func syncedDownloadHistory() -> [String] { Array(downloadHistory) }

    private func saveHistory() {
        guard let data = try? JSONEncoder().encode(Array(downloadHistory)) else { return }
        let dir = historyURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: historyURL)
    }

    private func loadHistory() {
        if let data = try? Data(contentsOf: historyURL),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            downloadHistory = Set(ids)
        }
        // Anything already on disk is by definition part of the history — seed it
        // so existing users' current downloads enter history on first launch of
        // this version (loadManifest runs before loadHistory). Persist the seed so
        // a later delete-then-restart can't lose an id that was never written.
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

    private func encodedURL(from rawURL: String) throws -> URL {
        guard let url = URL(string: rawURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? rawURL) else {
            throw URLError(.badURL)
        }
        return url
    }

    private func downloadWithProgress(url: URL, discourseID: String) async throws -> URL {
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        // Per-request cellular gate (URLSession.shared's config is immutable).
        // The toggle lives in Settings → Player & Downloads and defaults off.
        request.allowsCellularAccess = UserSettings.shared.allowCellularDownloads

        let task = URLSession.shared.downloadTask(with: request)
        activeTasks[discourseID] = task

        let observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            Task { @MainActor [weak self] in
                self?.activeDownloads[discourseID]?.progress = progress.fractionCompleted
            }
        }

        defer {
            observation.invalidate()
            activeTasks.removeValue(forKey: discourseID)
        }

        let tempURL: URL
        let response: URLResponse
        do {
            (tempURL, response) = try await withTaskCancellationHandler {
                try await URLSession.shared.download(for: request)
            } onCancel: {
                task.cancel()
            }
        } catch let error as URLError {
            // Translate the two transport failures the listener can actually act
            // on. Everything else keeps its system description.
            switch error.code {
            case .dataNotAllowed: throw DownloadError.wifiOnly   // cellular gate blocked it
            case .notConnectedToInternet, .networkConnectionLost: throw DownloadError.offline
            default: throw error
            }
        }

        // Validate response
        if let httpResponse = response as? HTTPURLResponse {
            guard (200...299).contains(httpResponse.statusCode) else {
                try? FileManager.default.removeItem(at: tempURL)
                throw httpResponse.statusCode == 404
                    ? DownloadError.notFound
                    : DownloadError.serverError(httpResponse.statusCode)
            }
            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
            if contentType.contains("text/html") {
                try? FileManager.default.removeItem(at: tempURL)
                throw DownloadError.notAudio
            }
        }

        // Move to a stable temp location so the caller can move it to final destination
        let stableTempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mp3")
        try FileManager.default.moveItem(at: tempURL, to: stableTempURL)
        return stableTempURL
    }
}
