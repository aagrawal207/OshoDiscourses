import AVFoundation
import CryptoKit
import Darwin
import Foundation
import os

enum NarrationPreparationError: LocalizedError {
    case busy, invalidSelection, emptyTranscript, invalidTranslation, invalidAudio, storage

    var errorDescription: String? {
        switch self {
        case .busy: "Another narration is being prepared or removed. Please try again shortly."
        case .invalidSelection: "Choose a different target language and a voice for that language. The source must be English or Hindi."
        case .emptyTranscript: "This transcript has no usable text for narration."
        case .invalidTranslation: "Translation did not return text for every passage. Please try again."
        case .invalidAudio: "The generated audio could not be verified. Saved passages can be reused when you retry."
        case .storage: "Narration could not be saved. Check available storage and try again."
        }
    }
}

actor NarrationCache {
    // Changing chunk boundaries or speech settings must invalidate earlier renditions.
    private static let renderVersion = 1
    private static let maximumChunkLength = 1_800
    private static let finalFileName = "narration.m4a"
    private static let manifestFileName = "manifest.json"
    private static let log = Logger(subsystem: "com.agraabhi.oshodiscourses", category: "Narration")

    struct Chunk: Sendable {
        let index: Int
        let sourceParagraphIndex: Int
        let text: String
    }

    struct Plan: Sendable {
        let document: NarrationDocument
        let chunks: [Chunk]

        init(transcript: Transcript, selection: NarrationSelection) throws {
            try NarrationCache.validate(selection)
            guard !transcript.discourseID.isEmpty,
                  zip(transcript.paragraphs, transcript.paragraphs.dropFirst()).allSatisfy({ $0.index < $1.index }),
                  transcript.paragraphs.allSatisfy({ $0.index >= 0 }) else {
                throw NarrationPreparationError.emptyTranscript
            }
            let source = transcript.paragraphs.map { SourceParagraph(index: $0.index, text: $0.text) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let digest = try NarrationCache.digest(encoder.encode(source))
            var chunks: [Chunk] = []
            for paragraph in transcript.paragraphs {
                for text in try NarrationCache.split(paragraph.text) {
                    chunks.append(Chunk(index: chunks.count, sourceParagraphIndex: paragraph.index, text: text))
                }
            }
            guard !chunks.isEmpty else { throw NarrationPreparationError.emptyTranscript }
            self.chunks = chunks
            document = NarrationDocument(
                id: try NarrationCache.documentID(discourseID: transcript.discourseID, digest: digest, selection: selection),
                discourseID: transcript.discourseID, sourceDigest: digest, selection: selection,
                expectedSegmentCount: chunks.count, segments: [], audioFileName: nil, duration: 0, updatedAt: Date()
            )
        }

        private struct SourceParagraph: Encodable {
            let index: Int
            let text: String
        }
    }

    // Cancellation and a short atomic commit share a lock; hashing/decoding never holds it.
    final class Job: @unchecked Sendable {
        let id = UUID()
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool { lock.withLock { cancelled } }

        func cancel() { lock.withLock { cancelled = true } }

        func check() throws {
            try Task.checkCancellation()
            if isCancelled { throw CancellationError() }
        }

        func commit<T>(_ operation: () throws -> T) throws -> T {
            try lock.withLock {
                try Task.checkCancellation()
                guard !cancelled else { throw CancellationError() }
                return try operation()
            }
        }
    }

    struct Snapshot: Sendable {
        let document: NarrationDocument
        fileprivate let files: [String: FileStamp]
    }

    fileprivate struct FileStamp: Equatable, Sendable {
        let size: Int
        let modified: Date
        let fileNumber: UInt64

        static func read(_ url: URL) throws -> FileStamp {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.intValue > 0,
                  let modified = attributes[.modificationDate] as? Date,
                  let number = attributes[.systemFileNumber] as? NSNumber else {
                throw NarrationPreparationError.invalidAudio
            }
            return FileStamp(size: size.intValue, modified: modified, fileNumber: number.uint64Value)
        }
    }

    private struct Artifact: Codable, Sendable {
        let bytes: Int
        let digest: String
        let duration: TimeInterval
    }

    private struct Manifest: Codable, Sendable {
        let version: Int
        var document: NarrationDocument
        var artifacts: [String: Artifact]
        // Optional so existing renditions keep their identity and remain readable.
        var pendingTranslations: [Int: String]?
        var pendingNeedsRepair = false

        private enum CodingKeys: String, CodingKey {
            case version, document, artifacts, pendingTranslations
        }

        private struct SegmentKey: CodingKey {
            let stringValue: String
            var intValue: Int? { Int(stringValue) }
            init(stringValue: String) { self.stringValue = stringValue }
            init(intValue: Int) { stringValue = String(intValue) }
        }

        init(version: Int, document: NarrationDocument, artifacts: [String: Artifact]) {
            self.version = version
            self.document = document
            self.artifacts = artifacts
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            document = try container.decode(NarrationDocument.self, forKey: .document)
            artifacts = try container.decode([String: Artifact].self, forKey: .artifacts)
            guard container.contains(.pendingTranslations),
                  (try? container.decodeNil(forKey: .pendingTranslations)) != true else { return }
            // A damaged optional text entry must not discard healthy audio or other saved passages.
            guard let pending = try? container.nestedContainer(keyedBy: SegmentKey.self, forKey: .pendingTranslations) else {
                pendingNeedsRepair = true
                return
            }
            var texts: [Int: String] = [:]
            for key in pending.allKeys {
                guard let index = key.intValue, String(index) == key.stringValue,
                      let text = try? pending.decode(String.self, forKey: key) else {
                    pendingNeedsRepair = true
                    continue
                }
                texts[index] = text
            }
            pendingTranslations = texts.isEmpty ? nil : texts
        }
    }

    private struct Session {
        let plan: Plan
        var manifest: Manifest
    }

    private struct Owner: Decodable {
        struct Document: Decodable { let discourseID: String }
        let document: Document
    }

    private let directory: URL
    private var sessions: [UUID: Session] = [:]

    init(directory: URL) {
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
    }

    func load() throws -> [Snapshot] {
        try ensureDirectory(directory)
        try clearAbandonedStaging()
        var result: [Snapshot] = []
        for id in try entryIDs() {
            try Task.checkCancellation()
            if let entry = try readEntry(id: id) { result.append(entry.snapshot) }
        }
        return result
    }

    func start(plan: Plan, job: Job) throws -> Snapshot {
        try job.check()
        try ensureDirectory(directory)
        try clearAbandonedStaging()
        let id = plan.document.id
        let entry = try readEntry(id: id, plan: plan, job: job)
        try job.check()
        if let entry, entry.snapshot.document.isComplete { return entry.snapshot }

        let manifest = entry?.manifest ?? Manifest(version: Self.renderVersion, document: plan.document, artifacts: [:])
        try ensureDirectory(entryURL(id))
        try ensureDirectory(stagingRoot)
        try ensureDirectory(stagingURL(job))
        try job.commit { try write(manifest) }
        try removeUnreferencedAudio(manifest)
        sessions[job.id] = Session(plan: plan, manifest: manifest)
        return Snapshot(document: manifest.document, files: [:])
    }

    func outputURL(segment index: Int?, job: Job) throws -> URL {
        try job.check()
        guard let session = sessions[job.id] else { throw CancellationError() }
        if let index, !session.plan.chunks.indices.contains(index) { throw CancellationError() }
        return stagingURL(job).appendingPathComponent(index.map(Self.segmentFileName) ?? Self.finalFileName)
    }

    func discardOutput(segment index: Int, job: Job) throws {
        let output = try outputURL(segment: index, job: job)
        try removeIfPresent(output)
    }

    func pendingTranslations(job: Job) throws -> [Int: String] {
        try job.check()
        guard let session = sessions[job.id] else { throw CancellationError() }
        return session.manifest.pendingTranslations ?? [:]
    }

    func saveTranslations(_ translations: [Int: String], job: Job) throws {
        try job.check()
        guard var session = sessions[job.id] else { throw CancellationError() }
        guard !translations.isEmpty, translations.allSatisfy({ index, text in
            session.plan.chunks.indices.contains(index)
                && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { throw NarrationPreparationError.invalidTranslation }
        var pending = session.manifest.pendingTranslations ?? [:]
        pending.merge(translations) { _, translated in translated }
        for segment in session.manifest.document.segments { pending[segment.index] = nil }
        session.manifest.pendingTranslations = pending.isEmpty ? nil : pending
        session.manifest.document.updatedAt = Date()
        try job.commit { try write(session.manifest) }
        sessions[job.id] = session
        Self.log.debug("stage=translationCache outcome=saved")
    }

    func segmentURLs(job: Job) throws -> [URL] {
        try job.check()
        guard let session = sessions[job.id],
              session.manifest.document.segments.count == session.plan.chunks.count else {
            throw NarrationPreparationError.invalidAudio
        }
        return session.manifest.document.segments.map {
            entryURL(session.plan.document.id).appendingPathComponent(Self.segmentFileName($0.index))
        }
    }

    func checkpoint(index: Int, text: String, duration: TimeInterval, job: Job) throws -> Snapshot {
        try job.check()
        guard var session = sessions[job.id], session.plan.chunks.indices.contains(index) else {
            throw CancellationError()
        }
        let name = Self.segmentFileName(index)
        let staged = stagingURL(job).appendingPathComponent(name)
        let artifact = try inspect(staged, duration: duration, job: job)
        let chunk = session.plan.chunks[index]
        session.manifest.document.segments.removeAll { $0.index == index }
        session.manifest.document.segments.append(NarrationSegment(
            index: index, sourceParagraphIndex: chunk.sourceParagraphIndex, text: text,
            audioFileName: name, duration: artifact.duration
        ))
        session.manifest.document.segments.sort { $0.index < $1.index }
        session.manifest.document.updatedAt = Date()
        session.manifest.artifacts[name] = artifact
        session.manifest.pendingTranslations?[index] = nil
        if session.manifest.pendingTranslations?.isEmpty == true { session.manifest.pendingTranslations = nil }
        try install(staged, name: name, manifest: session.manifest, job: job)
        sessions[job.id] = session
        return Snapshot(document: session.manifest.document, files: [:])
    }

    func finish(duration: TimeInterval, job: Job) throws -> Snapshot {
        try job.check()
        guard var session = sessions[job.id],
              session.manifest.document.segments.count == session.plan.chunks.count else {
            throw CancellationError()
        }
        let staged = stagingURL(job).appendingPathComponent(Self.finalFileName)
        let artifact = try inspect(staged, duration: duration, job: job)
        let expectedDuration = session.manifest.document.segments.reduce(0) { $0 + $1.duration }
        guard abs(artifact.duration - expectedDuration) <= Self.assemblyTolerance(session.plan.chunks.count) else {
            throw NarrationPreparationError.invalidAudio
        }
        var files: [String: FileStamp] = [:]
        for segment in session.manifest.document.segments {
            guard let receipt = session.manifest.artifacts[segment.audioFileName] else {
                throw NarrationPreparationError.invalidAudio
            }
            files[segment.audioFileName] = try verify(
                entryURL(session.plan.document.id).appendingPathComponent(Self.segmentFileName(segment.index)),
                artifact: receipt, duration: segment.duration, job: job
            )
        }
        session.manifest.document.audioFileName = Self.finalFileName
        session.manifest.document.duration = artifact.duration
        session.manifest.document.updatedAt = Date()
        session.manifest.artifacts[Self.finalFileName] = artifact
        try install(staged, name: Self.finalFileName, manifest: session.manifest, job: job)
        files[Self.finalFileName] = try FileStamp.read(entryURL(session.plan.document.id).appendingPathComponent(Self.finalFileName))
        files[Self.manifestFileName] = try FileStamp.read(entryURL(session.plan.document.id).appendingPathComponent(Self.manifestFileName))
        sessions[job.id] = session
        return Snapshot(document: session.manifest.document, files: files)
    }

    func discardStaging(job: Job) {
        sessions[job.id] = nil
        do {
            try removeIfPresent(stagingURL(job))
        } catch {
            Self.log.error("stage=cleanup outcome=failed")
        }
    }

    func remove(_ id: String) throws {
        guard Self.isID(id) else { throw NarrationPreparationError.storage }
        sessions = sessions.filter { $0.value.plan.document.id != id }
        try removeIfPresent(entryURL(id))
    }

    func ids(for discourseID: String) throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try entryIDs().filter { id in
            guard Self.isDirectory(entryURL(id)) else { return false }
            let url = entryURL(id).appendingPathComponent(Self.manifestFileName)
            guard (try? FileStamp.read(url)) != nil,
                  let data = try? Data(contentsOf: url),
                  let owner = try? JSONDecoder().decode(Owner.self, from: data) else { return false }
            return owner.document.discourseID == discourseID
        }
    }

    nonisolated func audioURL(for snapshot: Snapshot) -> URL? {
        let document = snapshot.document
        guard document.isComplete, Self.isID(document.id),
              document.audioFileName == Self.finalFileName,
              snapshot.files.count == document.expectedSegmentCount + 2,
              Self.isDirectory(entryURL(document.id)) else { return nil }
        for (name, stamp) in snapshot.files {
            guard let current = try? FileStamp.read(entryURL(document.id).appendingPathComponent(name)),
                  stamp == current else { return nil }
        }
        return entryURL(document.id).appendingPathComponent(Self.finalFileName)
    }

    /// Committed passages are immutable once their checkpoint is installed, so they can play while later ones render.
    nonisolated func segmentURL(documentID: String, index: Int) -> URL {
        entryURL(documentID).appendingPathComponent(Self.segmentFileName(index))
    }

    nonisolated static func isID(_ id: String) -> Bool {
        id.utf8.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    // MARK: - Recovery

    private func readEntry(id: String, plan: Plan? = nil, job: Job? = nil) throws -> (manifest: Manifest, snapshot: Snapshot)? {
        guard Self.isDirectory(entryURL(id)) else { return nil }
        let original: Manifest
        do {
            original = try decode(id: id)
        } catch {
            Self.log.notice("stage=cache outcome=invalidManifest")
            return nil
        }
        let document = original.document
        guard original.version == Self.renderVersion, document.id == id, Self.isID(document.sourceDigest),
              !document.discourseID.isEmpty, document.expectedSegmentCount > 0, document.updatedAt.timeIntervalSince1970.isFinite,
              (try? Self.documentID(discourseID: document.discourseID, digest: document.sourceDigest, selection: document.selection)) == id,
              plan == nil || plan?.document.expectedSegmentCount == document.expectedSegmentCount else {
            Self.log.notice("stage=cache outcome=invalidManifest")
            return nil
        }
        var repaired = Manifest(version: original.version, document: document, artifacts: [:])
        var pending = (original.pendingTranslations ?? [:]).filter { index, text in
            index >= 0 && index < document.expectedSegmentCount
                && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        repaired.document.segments = []
        repaired.document.audioFileName = nil
        repaired.document.duration = 0
        var files: [String: FileStamp] = [:]
        let counts = Dictionary(grouping: document.segments, by: \.index).mapValues(\.count)
        var previousParagraph = -1
        for segment in document.segments.sorted(by: { $0.index < $1.index }) {
            try check(job)
            guard segment.index >= 0, segment.index < document.expectedSegmentCount,
                  counts[segment.index] == 1, segment.sourceParagraphIndex >= previousParagraph,
                  segment.sourceParagraphIndex >= 0,
                  segment.audioFileName == Self.segmentFileName(segment.index),
                  !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let artifact = original.artifacts[segment.audioFileName],
                   plan == nil || plan?.chunks[segment.index].sourceParagraphIndex == segment.sourceParagraphIndex else { continue }
            // A damaged AAC file does not invalidate the already translated passage.
            pending[segment.index] = segment.text
            do {
                let name = Self.segmentFileName(segment.index)
                files[name] = try verify(entryURL(id).appendingPathComponent(name), artifact: artifact, duration: segment.duration, job: job)
                repaired.document.segments.append(segment)
                repaired.artifacts[name] = artifact
                previousParagraph = segment.sourceParagraphIndex
                pending[segment.index] = nil
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Self.log.notice("stage=cache outcome=invalidSegment")
            }
        }
        repaired.pendingTranslations = pending.isEmpty ? nil : pending
        if repaired.document.segments.count == document.expectedSegmentCount,
           document.audioFileName == Self.finalFileName,
           let artifact = original.artifacts[Self.finalFileName],
           abs(document.duration - repaired.document.segments.reduce(0) { $0 + $1.duration }) <= Self.assemblyTolerance(document.expectedSegmentCount) {
            do {
                files[Self.finalFileName] = try verify(
                    entryURL(id).appendingPathComponent(Self.finalFileName), artifact: artifact, duration: document.duration, job: job
                )
                repaired.document.audioFileName = Self.finalFileName
                repaired.document.duration = artifact.duration
                repaired.artifacts[Self.finalFileName] = artifact
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Self.log.notice("stage=cache outcome=invalidAssembly")
            }
        }
        if repaired.document != original.document || repaired.artifacts.keys != original.artifacts.keys
            || repaired.pendingTranslations != original.pendingTranslations || original.pendingNeedsRepair {
            try check(job)
            if let job {
                try job.commit { try write(repaired) }
            } else {
                try write(repaired)
            }
            try removeUnreferencedAudio(repaired)
            Self.log.notice("stage=cache outcome=repaired")
        }
        if repaired.document.isComplete {
            files[Self.manifestFileName] = try FileStamp.read(entryURL(id).appendingPathComponent(Self.manifestFileName))
        }
        return (repaired, Snapshot(document: repaired.document, files: repaired.document.isComplete ? files : [:]))
    }

    private func decode(id: String) throws -> Manifest {
        guard Self.isDirectory(entryURL(id)) else { throw NarrationPreparationError.storage }
        let url = entryURL(id).appendingPathComponent(Self.manifestFileName)
        _ = try FileStamp.read(url)
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    }

    private func install(_ staged: URL, name: String, manifest: Manifest, job: Job) throws {
        guard Self.isDirectory(entryURL(manifest.document.id)) else { throw NarrationPreparationError.storage }
        let destination = entryURL(manifest.document.id).appendingPathComponent(name)
        try excludeFromBackup(staged)
        try job.commit {
            try removeIfPresent(destination)
            try FileManager.default.moveItem(at: staged, to: destination)
            do {
                try write(manifest)
            } catch {
                try? removeIfPresent(destination)
                throw error
            }
        }
    }

    private func write(_ manifest: Manifest) throws {
        let folder = entryURL(manifest.document.id)
        guard Self.isDirectory(folder) else { throw NarrationPreparationError.storage }
        let url = folder.appendingPathComponent(Self.manifestFileName)
        let pending = folder.appendingPathComponent(".manifest-\(UUID().uuidString).json")
        defer { try? removeIfPresent(pending) }
        try JSONEncoder().encode(manifest).write(to: pending, options: .atomic)
        try excludeFromBackup(pending)
        guard rename(pending.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func removeUnreferencedAudio(_ manifest: Manifest) throws {
        let referenced = Set(manifest.artifacts.keys)
        for url in try FileManager.default.contentsOfDirectory(at: entryURL(manifest.document.id), includingPropertiesForKeys: nil) {
            let name = url.lastPathComponent
            let number = name.hasPrefix("segment-") && name.hasSuffix(".m4a")
                ? Int(name.dropFirst("segment-".count).dropLast(".m4a".count)) : nil
            let generated = name == Self.finalFileName || number.map { $0 >= 0 && Self.segmentFileName($0) == name } == true
            if generated, !referenced.contains(name) { try removeIfPresent(url) }
        }
    }

    // MARK: - Bounded file validation

    private func inspect(_ url: URL, duration: TimeInterval, job: Job) throws -> Artifact {
        guard duration.isFinite, duration > 0 else { throw NarrationPreparationError.invalidAudio }
        let before = try FileStamp.read(url)
        let measured = try audioDuration(url, decode: true, job: job)
        guard abs(measured - duration) <= max(0.25, measured * 0.002) else {
            throw NarrationPreparationError.invalidAudio
        }
        let digest = try fileDigest(url, job: job)
        guard before == (try FileStamp.read(url)) else { throw NarrationPreparationError.invalidAudio }
        return Artifact(bytes: before.size, digest: digest, duration: measured)
    }

    private func verify(_ url: URL, artifact: Artifact, duration: TimeInterval, job: Job?) throws -> FileStamp {
        try check(job)
        guard duration.isFinite, duration > 0, artifact.duration.isFinite,
              abs(duration - artifact.duration) < 0.000_001, Self.isID(artifact.digest) else {
            throw NarrationPreparationError.invalidAudio
        }
        let stamp = try FileStamp.read(url)
        guard stamp.size == artifact.bytes,
              abs(try audioDuration(url, decode: false, job: job) - duration) < 0.000_001,
              try fileDigest(url, job: job) == artifact.digest,
              stamp == (try FileStamp.read(url)) else { throw NarrationPreparationError.invalidAudio }
        return stamp
    }

    private func audioDuration(_ url: URL, decode: Bool, job: Job?) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        defer { file.close() }
        let length = file.length
        let rate = file.processingFormat.sampleRate
        guard file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC,
              rate.isFinite, rate > 0, length > 0 else { throw NarrationPreparationError.invalidAudio }
        if decode {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_192) else {
                throw NarrationPreparationError.invalidAudio
            }
            var frames: AVAudioFramePosition = 0
            while frames < length {
                try check(job)
                try file.read(into: buffer, frameCount: AVAudioFrameCount(min(8_192, length - frames)))
                guard buffer.frameLength > 0 else { throw NarrationPreparationError.invalidAudio }
                frames += AVAudioFramePosition(buffer.frameLength)
            }
            guard frames == length else { throw NarrationPreparationError.invalidAudio }
        }
        return Double(length) / rate
    }

    private func fileDigest(_ url: URL, job: Job?) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try check(job)
            guard let data = try handle.read(upToCount: 65_536), !data.isEmpty else { break }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Paths and identity

    private var stagingRoot: URL { directory.appendingPathComponent(".staging", isDirectory: true) }

    private func stagingURL(_ job: Job) -> URL { stagingRoot.appendingPathComponent(job.id.uuidString, isDirectory: true) }

    private nonisolated func entryURL(_ id: String) -> URL { directory.appendingPathComponent(id, isDirectory: true) }

    private nonisolated static func segmentFileName(_ index: Int) -> String { "segment-\(index).m4a" }

    private nonisolated static func assemblyTolerance(_ count: Int) -> TimeInterval {
        // Independently encoded AAC passages may each contribute one priming packet.
        max(0.25, Double(count) * 0.05)
    }

    private func entryIDs() throws -> [String] {
        guard Self.isDirectory(directory) else { throw NarrationPreparationError.storage }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent).filter(Self.isID)
    }

    private func clearAbandonedStaging() throws {
        guard Self.isDirectory(stagingRoot) else { return }
        for url in try FileManager.default.contentsOfDirectory(at: stagingRoot, includingPropertiesForKeys: nil) {
            if let id = UUID(uuidString: url.lastPathComponent), sessions[id] == nil { try removeIfPresent(url) }
        }
    }

    private func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard Self.isDirectory(url) else { throw NarrationPreparationError.storage }
        try excludeFromBackup(url)
    }

    private nonisolated static func isDirectory(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory
    }

    private func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = url
        try url.setResourceValues(values)
    }

    private func removeIfPresent(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
        }
    }

    private func check(_ job: Job?) throws {
        try Task.checkCancellation()
        try job?.check()
    }

    private nonisolated static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func documentID(discourseID: String, digest: String, selection: NarrationSelection) throws -> String {
        try validate(selection)
        var parts = [
            String(renderVersion), discourseID, digest,
            canonicalLanguage(selection.sourceLanguage), canonicalLanguage(selection.targetLanguage),
            selection.voice.id, canonicalLanguage(selection.voice.language), String(selection.voice.quality),
        ]
        // Natural pace leaves the identity unchanged, so renditions saved before pacing still match.
        if selection.pace != .natural { parts.append(selection.pace.rawValue) }
        return Self.digest(try JSONEncoder().encode(parts))
    }

    private nonisolated static func canonicalLanguage(_ value: String) -> String {
        Locale.canonicalLanguageIdentifier(from: value.trimmingCharacters(in: .whitespacesAndNewlines))
            .replacingOccurrences(of: "_", with: "-").lowercased()
    }

    private nonisolated static func validate(_ selection: NarrationSelection) throws {
        func language(_ identifier: String) -> String? {
            let canonical = canonicalLanguage(identifier)
            guard !canonical.isEmpty, canonical.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else { return nil }
            return Locale.Language(identifier: canonical).languageCode?.identifier
        }
        guard let source = language(selection.sourceLanguage), ["en", "hi"].contains(source),
              let target = language(selection.targetLanguage), target != "und", source != target,
              language(selection.voice.language) == target,
              !selection.voice.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NarrationPreparationError.invalidSelection
        }
    }

    private nonisolated static func split(_ original: String) throws -> [String] {
        let text = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        guard text.utf16.count > maximumChunkLength else { return [text] }
        var pieces: [String] = []
        var pending = ""
        for range in TranscriptBlocks.sentenceRanges(in: text) {
            var remaining = text[range]
            while !remaining.isEmpty {
                var end = remaining.startIndex
                var lastSpace: String.Index?
                var length = 0
                while end < remaining.endIndex {
                    let next = remaining.index(after: end)
                    let count = remaining[end..<next].utf16.count
                    if length + count > maximumChunkLength { break }
                    length += count
                    if remaining[end].isWhitespace { lastSpace = end }
                    end = next
                }
                guard end > remaining.startIndex else { throw NarrationPreparationError.emptyTranscript }
                if end < remaining.endIndex, let space = lastSpace, space > remaining.startIndex { end = space }
                let piece = remaining[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty {
                    if !pending.isEmpty, pending.utf16.count + 1 + piece.utf16.count > maximumChunkLength {
                        pieces.append(pending)
                        pending = ""
                    }
                    pending += (pending.isEmpty ? "" : " ") + piece
                }
                remaining = remaining[end...]
                while let first = remaining.first, first.isWhitespace { remaining = remaining.dropFirst() }
            }
        }
        if !pending.isEmpty { pieces.append(pending) }
        return pieces
    }
}
