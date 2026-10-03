import Foundation
import OSLog

/// A discourse stored on the watch for listening without the phone.
struct OfflineEntry: Codable, Equatable, Identifiable, Sendable {
    var discourseID: String
    var title: String
    var series: String
    var duration: Double
    var fileName: String
    var byteCount: Int64
    var addedAt: Date
    /// Where listening stands: the Watch's own playback or newer phone progress, whichever is later.
    var position: Double
    var finished: Bool
    /// When `position` last moved, here or on the phone. Nil in indexes written before stamps.
    var positionUpdatedAt: Date?

    var id: String { discourseID }

    var progress: Double? {
        if finished { return 1 }
        guard duration > 0, position > 0 else { return nil }
        return min(1, position / duration)
    }

    /// Where local playback starts: a finished or nearly finished talk starts over.
    var startPosition: Double {
        guard position.isFinite, position > 0, !finished else { return 0 }
        if duration > 0, position >= duration - 5 { return 0 }
        return position
    }
}

enum OfflineStoreError: Error, Equatable {
    case missingMetadata
    case moveFailed
}

/// Owns `Application Support/Offline`. Lock-protected so WatchConnectivity's delegate queue can
/// move an arriving file and record it before the callback returns and the system deletes the file.
final class OfflineFileStore: @unchecked Sendable {
    static let indexFileName = "index.json"
    /// Matches the phone, which restamps its own position only after a move of a second or more.
    static let movementThreshold: Double = 1
    static let allowedExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "caf"]

    let directory: URL
    private let lock = NSLock()
    private var entries: [String: OfflineEntry] = [:]
    private let fileManager = FileManager.default

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Offline", isDirectory: true)
    }

    init(directory: URL = OfflineFileStore.defaultDirectory()) {
        self.directory = directory
        lock.withLock {
            prepareDirectory()
            loadIndex()
        }
    }

    // MARK: Reading

    func allEntries() -> [OfflineEntry] {
        lock.withLock { entries.values.sorted { $0.addedAt > $1.addedAt } }
    }

    func entry(for discourseID: String) -> OfflineEntry? {
        lock.withLock { entries[discourseID] }
    }

    func fileURL(for entry: OfflineEntry) -> URL {
        directory.appendingPathComponent(entry.fileName, isDirectory: false)
    }

    var inventory: [String] { lock.withLock { entries.keys.sorted() } }

    var totalBytes: Int64 { lock.withLock { entries.values.reduce(0) { $0 + $1.byteCount } } }

    // MARK: Writing

    /// Synchronous by design: called inside `session(_:didReceive:)`.
    @discardableResult
    func receive(fileAt source: URL, metadata: Data?) throws -> OfflineEntry {
        guard let metadata, let file = try? CompanionWire.decode(CompanionOfflineFile.self, from: metadata),
              !file.discourseID.isEmpty else { throw OfflineStoreError.missingMetadata }
        return try receive(fileAt: source, file: file)
    }

    @discardableResult
    func receive(fileAt source: URL, file: CompanionOfflineFile, now: Date = Date()) throws -> OfflineEntry {
        let ext = source.pathExtension.lowercased()
        let fileName = Self.sanitizedName(file.discourseID) + "." + (Self.allowedExtensions.contains(ext) ? ext : "mp3")
        return try lock.withLock {
            prepareDirectory()
            let destination = directory.appendingPathComponent(fileName, isDirectory: false)
            let previous = entries[file.discourseID]
            if let previous { try? fileManager.removeItem(at: directory.appendingPathComponent(previous.fileName)) }
            try? fileManager.removeItem(at: destination)
            do {
                try fileManager.moveItem(at: source, to: destination)
            } catch {
                // A move across volumes can fail where a copy succeeds; the source is deleted by the system anyway.
                do { try fileManager.copyItem(at: source, to: destination) } catch { throw OfflineStoreError.moveFailed }
            }
            Self.excludeFromBackup(destination)
            let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            var entry = OfflineEntry(
                discourseID: file.discourseID, title: file.title, series: file.series,
                duration: max(0, file.duration.isFinite ? file.duration : 0), fileName: fileName,
                byteCount: size, addedAt: now,
                position: max(0, file.resumePosition.isFinite ? file.resumePosition : 0),
                finished: false, positionUpdatedAt: file.resumeSavedAt
            )
            // A resend keeps whichever listening is newer, the Watch's own or the phone's.
            if let previous, (file.resumeSavedAt ?? .distantPast) <= (previous.positionUpdatedAt ?? .distantPast) {
                entry.position = previous.position
                entry.finished = previous.finished
                entry.positionUpdatedAt = previous.positionUpdatedAt
            }
            entries[file.discourseID] = entry
            saveIndex()
            Logger.watchOffline.info("offline file stored")
            return entry
        }
    }

    func delete(_ discourseID: String) {
        lock.withLock {
            guard let entry = entries.removeValue(forKey: discourseID) else { return }
            try? fileManager.removeItem(at: directory.appendingPathComponent(entry.fileName))
            saveIndex()
        }
    }

    /// Local listening; returns whether any happened. As on the phone, only a move of 1 s or more, or finishing,
    /// restamps the position: an unmoved save must not outrank newer listening on the phone.
    @discardableResult
    func updatePosition(
        _ discourseID: String, position: Double, duration: Double? = nil, finished: Bool, at date: Date = Date()
    ) -> Bool {
        lock.withLock {
            guard var entry = entries[discourseID], position.isFinite else { return false }
            let position = max(0, position)
            var durationChanged = false
            if let duration, duration.isFinite, duration > 0, duration != entry.duration {
                entry.duration = duration
                durationChanged = true
            }
            let moved = abs(position - entry.position) >= Self.movementThreshold
            // Stopping or backgrounding at the end of a finished talk saves it unfinished; that is not listening.
            let listened = moved || (finished && !entry.finished)
            if listened {
                entry.position = position
                entry.finished = finished
                entry.positionUpdatedAt = date
            }
            if listened || durationChanged {
                entries[discourseID] = entry
                saveIndex()
            }
            return listened
        }
    }

    /// Takes the phone's listening for stored talks where it is newer than the Watch's, except `loadedID`:
    /// a session loaded in the local player is never moved under the listener. Returns the ids that changed.
    @discardableResult
    func adoptPhonePositions(_ positions: [CompanionSavedPosition], skipping loadedID: String?) -> [String] {
        lock.withLock {
            var changed: [String] = []
            for saved in positions where saved.discourseID != loadedID {
                guard var entry = entries[saved.discourseID], saved.position.isFinite, saved.position >= 0,
                      saved.savedAt > (entry.positionUpdatedAt ?? .distantPast) else { continue }
                entry.position = saved.position
                entry.finished = saved.finished
                entry.positionUpdatedAt = saved.savedAt
                entries[saved.discourseID] = entry
                if !changed.contains(saved.discourseID) { changed.append(saved.discourseID) }
            }
            if !changed.isEmpty { saveIndex() }
            return changed
        }
    }

    // MARK: Helpers

    static func sanitizedName(_ id: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        var name = String(id.map { allowed.contains($0) ? $0 : "_" }.prefix(80))
        if name.isEmpty { name = "talk" }
        // Distinct ids that sanitize alike must not overwrite each other's audio.
        if name != id { name += "-" + String(fnv1a(id), radix: 16) }
        return name
    }

    private static func fnv1a(_ text: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash
    }

    private static func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = url
        try? target.setResourceValues(values)
    }

    private var indexURL: URL { directory.appendingPathComponent(Self.indexFileName, isDirectory: false) }

    private func prepareDirectory() {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.excludeFromBackup(directory)
    }

    private func loadIndex() {
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([OfflineEntry].self, from: data) {
            entries = Dictionary(decoded.map { ($0.discourseID, $0) }, uniquingKeysWith: { $1 })
        }
        let files = Set((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [])
        let missing = entries.values.filter { !files.contains($0.fileName) }
        for entry in missing { entries[entry.discourseID] = nil }
        // Audio without an index entry has no title to show and only costs storage.
        let indexed = Set(entries.values.map(\.fileName))
        for name in files where name != Self.indexFileName && !indexed.contains(name) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
        if !missing.isEmpty { saveIndex() }
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(Array(entries.values)) else { return }
        try? data.write(to: indexURL, options: .atomic)
        Self.excludeFromBackup(indexURL)
    }
}
