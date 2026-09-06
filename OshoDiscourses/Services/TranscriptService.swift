import Foundation

/// Fetches, caches and serves discourse transcripts.
///
/// Text arrives with the audio: `DownloadService` reports each committed
/// download and the transcript is fetched right behind it, so reading works
/// offline later. Opening a transcript that isn't cached fetches it on demand.
/// Cached files live in Application Support and are excluded from backup —
/// like the audio, they are re-downloadable and only bloat a device backup.
@Observable
@MainActor
final class TranscriptService {
    static let shared = TranscriptService()

    enum Availability: Equatable {
        /// oshoworld.com has no transcript for this discourse.
        case unavailable
        /// Exists on the site; not yet on this device.
        case notCached
        case cached
    }

    /// Discourses whose transcript is on disk. Observable so rows can react.
    private(set) var cachedIDs: Set<String> = []
    /// Discourses with a fetch in flight (on-demand or prefetch).
    private(set) var loadingIDs: Set<String> = []

    private var inFlight: [String: Task<Transcript, Error>] = [:]
    /// The few transcripts open recently; ~60 KB each, so a handful is plenty.
    private var memory: [String: Transcript] = [:]
    private var memoryOrder: [String] = []
    private static let memoryLimit = 4

    /// Words below which a fetched page is treated as blank rather than a
    /// transcript. Real ones run into the thousands; blanks are 0-1 words.
    static let minimumWords = 50

    private let directory: URL
    private let fetchHTML: (TranscriptCatalog.Entry, Bool) async throws -> String

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = appSupport.appendingPathComponent("transcripts", isDirectory: true)
        fetchHTML = { try await TranscriptFetcher.fetchDescriptionHTML(for: $0, allowsCellular: $1) }
        loadIndex()
    }

    /// Test seam: a service over a scratch directory with a stubbed network.
    init(directory: URL, fetchHTML: @escaping (TranscriptCatalog.Entry, Bool) async throws -> String) {
        self.directory = directory
        self.fetchHTML = fetchHTML
        loadIndex()
    }

    // MARK: - Queries

    func availability(for discourseID: String) -> Availability {
        if cachedIDs.contains(discourseID) { return .cached }
        return TranscriptCatalog.hasTranscript(discourseID) ? .notCached : .unavailable
    }

    func isLoading(_ discourseID: String) -> Bool {
        loadingIDs.contains(discourseID)
    }

    /// The transcript, from memory, disk, or the network (in that order).
    /// `allowsCellular` only matters for the network step; user-initiated reads
    /// pass true — the text is ~60 KB and the listener asked for it.
    func transcript(for discourseID: String, allowsCellular: Bool = true) async throws -> Transcript {
        if let cached = memory[discourseID] {
            touch(discourseID)
            return cached
        }
        if let onDisk = readFromDisk(discourseID) {
            remember(onDisk)
            return onDisk
        }
        if let running = inFlight[discourseID] {
            return try await running.value
        }
        guard let entry = TranscriptCatalog.entry(for: discourseID) else {
            throw TranscriptFetcher.FetchError.noDescription
        }
        let fetch = fetchHTML
        let task = Task<Transcript, Error> {
            let html = try await fetch(entry, allowsCellular)
            // Parsing 60 KB of markup is a few milliseconds, but not on the
            // main actor while the reader is animating.
            let paragraphs = await Task.detached(priority: .userInitiated) {
                TranscriptParser.paragraphs(fromHTML: html)
            }.value
            let transcript = Transcript(discourseID: discourseID, sourceID: entry.id, fetchedAt: Date(), paragraphs: paragraphs)
            guard transcript.wordCount >= Self.minimumWords else { throw TranscriptFetcher.FetchError.blank }
            return transcript
        }
        inFlight[discourseID] = task
        loadingIDs.insert(discourseID)
        defer {
            inFlight.removeValue(forKey: discourseID)
            loadingIDs.remove(discourseID)
        }
        let transcript = try await task.value
        writeToDisk(transcript)
        remember(transcript)
        return transcript
    }

    /// Fire-and-forget fetch used right after an audio download commits.
    func prefetch(_ discourseID: String, allowsCellular: Bool = true) {
        guard availability(for: discourseID) == .notCached, inFlight[discourseID] == nil else { return }
        Task { _ = try? await transcript(for: discourseID, allowsCellular: allowsCellular) }
    }

    /// Fetch transcripts for already-downloaded discourses that predate this
    /// feature, one at a time so it never competes with an audio download.
    /// Stops after a few consecutive failures — that means we're offline.
    func backfill(downloadedIDs: [String], allowsCellular: Bool) {
        let missing = downloadedIDs.filter { availability(for: $0) == .notCached }
        guard !missing.isEmpty else { return }
        Task {
            var failures = 0
            for id in missing {
                do {
                    _ = try await transcript(for: id, allowsCellular: allowsCellular)
                    failures = 0
                } catch is TranscriptFetcher.FetchError {
                    // Blank or malformed page: a per-discourse problem, keep going.
                } catch {
                    failures += 1
                    if failures >= 3 { return }
                }
            }
        }
    }

    /// Drop the cached text (audio was deleted). Anchors and read positions are
    /// user data and are kept by TranscriptStateService.
    func remove(_ discourseID: String) {
        memory.removeValue(forKey: discourseID)
        memoryOrder.removeAll { $0 == discourseID }
        cachedIDs.remove(discourseID)
        try? FileManager.default.removeItem(at: fileURL(for: discourseID))
    }

    // MARK: - Disk

    private func fileURL(for discourseID: String) -> URL {
        // Ids are "<language>-<filePrefix>-<n>" and file prefixes are path-safe
        // identifiers, but guard anyway: a slash would escape the folder.
        let safe = discourseID.replacingOccurrences(of: "/", with: "-")
        return directory.appendingPathComponent(safe).appendingPathExtension("json")
    }

    private func loadIndex() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        cachedIDs = Set(files.filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent })
    }

    private func readFromDisk(_ discourseID: String) -> Transcript? {
        guard let data = try? Data(contentsOf: fileURL(for: discourseID)),
              let transcript = try? JSONDecoder().decode(Transcript.self, from: data) else {
            // Missing or corrupt: forget it so the next open re-fetches.
            cachedIDs.remove(discourseID)
            return nil
        }
        return transcript
    }

    private func writeToDisk(_ transcript: Transcript) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            excludeFromBackup(directory)
            let url = fileURL(for: transcript.discourseID)
            try JSONEncoder().encode(transcript).write(to: url, options: .atomic)
            excludeFromBackup(url)
            cachedIDs.insert(transcript.discourseID)
        } catch {
            print("[Transcripts] failed to cache \(transcript.discourseID): \(error)")
        }
    }

    private func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)
    }

    // MARK: - Memory

    private func remember(_ transcript: Transcript) {
        memory[transcript.discourseID] = transcript
        touch(transcript.discourseID)
        while memoryOrder.count > Self.memoryLimit, let oldest = memoryOrder.first {
            memoryOrder.removeFirst()
            memory.removeValue(forKey: oldest)
        }
    }

    private func touch(_ discourseID: String) {
        memoryOrder.removeAll { $0 == discourseID }
        memoryOrder.append(discourseID)
    }
}
