import Foundation

/// Where the reader last was in a transcript, so reopening lands on the same
/// paragraph instead of the top. A negative paragraph records "following the
/// audio again" with a timestamp, so that choice also beats an older position
/// arriving from another device instead of being resurrected by it.
struct TranscriptReadPosition: Codable, Equatable, Sendable {
    let paragraph: Int
    let updatedAt: Date

    var isFollowing: Bool { paragraph < 0 }

    static func following(at date: Date = Date()) -> TranscriptReadPosition {
        TranscriptReadPosition(paragraph: -1, updatedAt: date)
    }
}

/// Per-paragraph start times recovered by on-device speech recognition.
/// Device-local: it is derived data that any device can recompute, and at a
/// few KB per discourse it has no place in the 1 MB iCloud key-value store.
struct TranscriptAlignment: Codable, Equatable, Sendable {
    /// Start time of each paragraph; nil where no confident match was found.
    let starts: [TimeInterval?]
    let createdAt: Date
    /// Recogniser and locale that produced it, e.g. "SpeechTranscriber/en-US".
    let engine: String

    var matchedCount: Int { starts.compactMap { $0 }.count }
}

/// Everything the app remembers about one discourse's transcript.
struct TranscriptDiscourseState: Codable, Equatable, Sendable {
    var anchors: [TranscriptAnchor] = []
    var readPosition: TranscriptReadPosition?
    var alignment: TranscriptAlignment?
    /// Paragraph count of the transcript the anchors and alignment refer to.
    /// If the text is re-fetched with a different split, they no longer point
    /// at the right paragraphs and are dropped.
    var paragraphCount: Int?

    var lastActivity: Date {
        max(readPosition?.updatedAt ?? .distantPast, anchors.map(\.createdAt).max() ?? .distantPast)
    }

    var isEmpty: Bool { anchors.isEmpty && readPosition == nil && alignment == nil }
}

/// The slice of `TranscriptDiscourseState` that syncs between devices.
struct TranscriptSyncedState: Codable, Equatable, Sendable {
    var anchors: [TranscriptAnchor] = []
    var readPosition: TranscriptReadPosition?
    var paragraphCount: Int?

    var lastActivity: Date {
        max(readPosition?.updatedAt ?? .distantPast, anchors.map(\.createdAt).max() ?? .distantPast)
    }
}

@Observable
@MainActor
final class TranscriptStateService {
    static let shared = TranscriptStateService()

    private(set) var states: [String: TranscriptDiscourseState] = [:]

    /// Fired after a local anchor or read-position change is persisted so
    /// iCloud sync can push. Not fired by `mergeSynced` (already reconciling).
    var onChanged: (() -> Void)?

    /// Most recently active discourses whose anchors and read positions ride in
    /// the cloud snapshot. Keeps the payload to a few tens of KB.
    static let syncedDiscourseLimit = 300
    static let anchorsPerDiscourseLimit = 40

    private let fileURL: URL
    private var pendingSave: Task<Void, Never>?

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        fileURL = appSupport.appendingPathComponent("transcript_state.json")
        load()
    }

    /// Test seam over a scratch file.
    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    // MARK: - Reads

    /// State for a discourse, reconciled against the transcript actually on
    /// screen: a different paragraph count invalidates anchors and alignment.
    func state(for discourseID: String, paragraphCount: Int) -> TranscriptDiscourseState {
        var s = states[discourseID] ?? TranscriptDiscourseState()
        if let stored = s.paragraphCount, stored != paragraphCount {
            s.anchors = []
            s.alignment = nil
            s.paragraphCount = paragraphCount
            if let read = s.readPosition, !read.isFollowing, read.paragraph >= paragraphCount {
                s.readPosition = nil
            }
            states[discourseID] = s
            scheduleSave()
        }
        return s
    }

    func state(for discourseID: String) -> TranscriptDiscourseState? {
        states[discourseID]
    }

    // MARK: - Writes

    func addAnchor(discourseID: String, paragraph: Int, time: TimeInterval, paragraphCount: Int) {
        var s = state(for: discourseID, paragraphCount: paragraphCount)
        let anchor = TranscriptAnchor(paragraph: paragraph, time: time, createdAt: Date())
        s.anchors = Self.cap(TranscriptSyncModel.inserting(anchor, into: s.anchors))
        s.paragraphCount = paragraphCount
        states[discourseID] = s
        saveNow()
        onChanged?()
    }

    func clearAnchors(discourseID: String) {
        guard var s = states[discourseID], !s.anchors.isEmpty else { return }
        s.anchors = []
        states[discourseID] = s
        saveNow()
        onChanged?()
    }

    /// Debounced: fires while the reader scrolls, so the file write and the
    /// cloud push wait for a pause.
    func setReadPosition(discourseID: String, paragraph: Int, paragraphCount: Int) {
        var s = state(for: discourseID, paragraphCount: paragraphCount)
        guard s.readPosition?.paragraph != paragraph else { return }
        s.readPosition = TranscriptReadPosition(paragraph: paragraph, updatedAt: Date())
        s.paragraphCount = paragraphCount
        states[discourseID] = s
        scheduleSave(notify: true)
    }

    /// The reader is following the audio again; there is no place to return to.
    func clearReadPosition(discourseID: String) {
        guard var s = states[discourseID], let read = s.readPosition, !read.isFollowing else { return }
        s.readPosition = .following()
        states[discourseID] = s
        scheduleSave(notify: true)
    }

    func setAlignment(discourseID: String, alignment: TranscriptAlignment, paragraphCount: Int) {
        var s = state(for: discourseID, paragraphCount: paragraphCount)
        s.alignment = alignment
        s.paragraphCount = paragraphCount
        states[discourseID] = s
        saveNow()
    }

    func clearAlignment(discourseID: String) {
        guard var s = states[discourseID], s.alignment != nil else { return }
        s.alignment = nil
        states[discourseID] = s
        saveNow()
    }

    // MARK: - iCloud sync

    /// Anchors and read positions for the most recently active discourses.
    func syncedStates() -> [String: TranscriptSyncedState] {
        let recent = states
            .filter { !$0.value.anchors.isEmpty || $0.value.readPosition != nil }
            .sorted { $0.value.lastActivity > $1.value.lastActivity }
            .prefix(Self.syncedDiscourseLimit)
        var out: [String: TranscriptSyncedState] = [:]
        for (id, s) in recent {
            out[id] = TranscriptSyncedState(anchors: s.anchors, readPosition: s.readPosition, paragraphCount: s.paragraphCount)
        }
        return out
    }

    /// Merge another device's transcript state. Returns true if anything changed.
    @discardableResult
    func mergeSynced(_ incoming: [String: TranscriptSyncedState]) -> Bool {
        var changed = false
        for (id, remote) in incoming {
            let local = states[id]
            let localSynced = local.map { TranscriptSyncedState(anchors: $0.anchors, readPosition: $0.readPosition, paragraphCount: $0.paragraphCount) }
            let merged = Self.merge(local: localSynced, incoming: remote)
            guard merged != localSynced else { continue }
            var s = local ?? TranscriptDiscourseState()
            s.anchors = merged.anchors
            s.readPosition = merged.readPosition
            if s.paragraphCount != merged.paragraphCount {
                // The other device saw a differently split transcript and its
                // data won; our alignment refers to the old split.
                s.alignment = nil
                s.paragraphCount = merged.paragraphCount
            }
            states[id] = s
            changed = true
        }
        if changed { saveNow() }
        return changed
    }

    /// Order-independent merge of one discourse's synced state.
    ///
    /// Anchors union through `TranscriptSyncModel.merge` and the newer read
    /// position wins, provided both sides describe the same paragraph split.
    /// If the splits differ, the side with the more recent activity is taken
    /// whole — the same choice on every device, since it depends only on the
    /// two inputs.
    static func merge(local: TranscriptSyncedState?, incoming: TranscriptSyncedState) -> TranscriptSyncedState {
        guard let local else { return normalized(incoming) }
        if let a = local.paragraphCount, let b = incoming.paragraphCount, a != b {
            if local.lastActivity == incoming.lastActivity {
                return normalized(a > b ? local : incoming)
            }
            return normalized(local.lastActivity > incoming.lastActivity ? local : incoming)
        }
        var out = TranscriptSyncedState()
        out.anchors = cap(TranscriptSyncModel.merge(local.anchors, incoming.anchors))
        switch (local.readPosition, incoming.readPosition) {
        case let (l?, r?):
            // Equal timestamps are broken by paragraph so both devices pick
            // the same one instead of each keeping its own.
            if l.updatedAt != r.updatedAt { out.readPosition = r.updatedAt > l.updatedAt ? r : l }
            else { out.readPosition = r.paragraph > l.paragraph ? r : l }
        case let (l?, nil): out.readPosition = l
        case let (nil, r?): out.readPosition = r
        default: out.readPosition = nil
        }
        out.paragraphCount = local.paragraphCount ?? incoming.paragraphCount
        return out
    }

    private static func normalized(_ s: TranscriptSyncedState) -> TranscriptSyncedState {
        var out = s
        out.anchors = cap(TranscriptSyncModel.merge(s.anchors, []))
        return out
    }

    /// Keep the newest anchors when a discourse collects too many.
    private static func cap(_ anchors: [TranscriptAnchor]) -> [TranscriptAnchor] {
        guard anchors.count > anchorsPerDiscourseLimit else { return anchors }
        return anchors
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(anchorsPerDiscourseLimit)
            .sorted { $0.paragraph < $1.paragraph }
    }

    // MARK: - Persistence

    private func scheduleSave(notify: Bool = false) {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.saveNow()
            if notify { self.onChanged?() }
        }
    }

    private func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(states.filter { !$0.value.isEmpty })
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[Transcripts] failed to save state: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            states = try JSONDecoder().decode([String: TranscriptDiscourseState].self, from: data)
        } catch {
            let backupURL = fileURL.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.moveItem(at: fileURL, to: backupURL)
            print("[Transcripts] failed to decode transcript_state.json; preserved as \(backupURL.lastPathComponent): \(error)")
        }
    }
}
