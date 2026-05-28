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

    // Maps discourse ID → relative path from Documents
    private var pathMap: [String: String] = [:]

    private let manifestURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(".download_manifest.json")
    }()

    init() {
        loadManifest()
        migrateOldDownloads()
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

    func isDownloaded(_ discourseID: String) -> Bool {
        downloadedIDs.contains(discourseID)
    }

    func isDownloading(_ discourseID: String) -> Bool {
        guard let dl = activeDownloads[discourseID] else { return false }
        if case .downloading = dl.status { return true }
        return false
    }

    func progress(for discourseID: String) -> Double {
        activeDownloads[discourseID]?.progress ?? 0
    }

    func localFileURL(for discourseID: String) -> URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

        // Check manifest path first
        if let rel = pathMap[discourseID] {
            let url = docs.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        // Fallback: old flat path
        let oldPath = docs.appendingPathComponent("downloads/\(discourseID).mp3")
        if FileManager.default.fileExists(atPath: oldPath.path) {
            return oldPath
        }

        return nil
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
        try? data.write(to: manifestURL)
    }

    private func loadManifest() {
        guard let data = try? Data(contentsOf: manifestURL),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        pathMap = map
        downloadedIDs = Set(map.keys.filter { id in
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let path = docs.appendingPathComponent(map[id]!)
            return FileManager.default.fileExists(atPath: path.path)
        })
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
        guard let url = URL(string: rawURL.replacingOccurrences(of: " ", with: "%20")) else {
            throw URLError(.badURL)
        }
        return url
    }

    private func downloadWithProgress(url: URL, discourseID: String) async throws -> URL {
        var request = URLRequest(url: url)
        request.timeoutInterval = 120

        let task = URLSession.shared.downloadTask(with: request)
        let observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            Task { @MainActor [weak self] in
                self?.activeDownloads[discourseID]?.progress = progress.fractionCompleted
            }
        }
        defer { observation.invalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadTaskDelegate(continuation: continuation)
            objc_setAssociatedObject(task, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
            task.delegate = delegate
            task.resume()
        }
    }
}

private final class DownloadTaskDelegate: NSObject, URLSessionDownloadDelegate {
    private var continuation: CheckedContinuation<URL, Error>?

    init(continuation: CheckedContinuation<URL, Error>) {
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp3")
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            continuation?.resume(returning: dest)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
