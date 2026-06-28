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

    var activeDownloads: [String: DownloadProgress] = [:]
    private(set) var downloadedIDs: Set<String> = []
    private var activeTasks: [String: URLSessionDownloadTask] = [:]

    // Maps discourse ID → relative path from Documents
    private var pathMap: [String: String] = [:]

    private let maxConcurrent = 3

    private let manifestURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent(".download_manifest.json")
    }()

    init() {
        loadManifest()
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
            try FileManager.default.createDirectory(at: seriesDir, withIntermediateDirectories: true)

            let localURL = try await downloadWithProgress(url: url, discourseID: discourse.id)

            try FileManager.default.moveItem(at: localURL, to: destination)
            downloadedIDs.insert(discourse.id)
            pathMap[discourse.id] = relativePath(for: discourse)
            saveManifest()
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
        // When off, the task fails on cellular and surfaces via the .failed path.
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

        let (tempURL, response) = try await withTaskCancellationHandler {
            try await URLSession.shared.download(for: request)
        } onCancel: {
            task.cancel()
        }

        // Validate response
        if let httpResponse = response as? HTTPURLResponse {
            guard (200...299).contains(httpResponse.statusCode) else {
                try? FileManager.default.removeItem(at: tempURL)
                throw URLError(.badServerResponse)
            }
            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
            if contentType.contains("text/html") {
                try? FileManager.default.removeItem(at: tempURL)
                throw URLError(.badServerResponse)
            }
        }

        // Move to a stable temp location so the caller can move it to final destination
        let stableTempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mp3")
        try FileManager.default.moveItem(at: tempURL, to: stableTempURL)
        return stableTempURL
    }
}
