import Foundation

// Wire contract between the iPhone app and the Watch app. Foundation-only:
// compiled into both targets, so it must not reference catalog or service types.

enum CompanionWire {
    /// Both apps ship together; a peer with another version is rejected, not guessed at.
    static let version = 1
    /// WatchConnectivity message payloads stay well under the system's limit.
    static let maximumPayloadBytes = 60 * 1024
    /// Single application-context entry carrying the latest `CompanionSnapshot`.
    static let snapshotContextKey = "osho.snapshot.v1"
    /// `transferUserInfo` key for a Watch-side listening position report.
    static let positionReportKey = "osho.position.v1"
    /// `transferFile` metadata key for an offline discourse sent to the Watch.
    static let offlineFileMetadataKey = "osho.offline.v1"

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximumPayloadBytes else { throw CompanionError.payloadTooLarge }
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= maximumPayloadBytes else { throw CompanionError.payloadTooLarge }
        return try JSONDecoder().decode(type, from: data)
    }
}

enum CompanionError: Error, Equatable, Sendable {
    case payloadTooLarge
    case unsupportedVersion
    case malformed
}

/// What iPhone is playing. Positions are a phone-side sample; the Watch
/// interpolates from its own receipt clock, never the phone's wall clock.
struct CompanionNowPlaying: Codable, Equatable, Sendable {
    var discourseID: String
    var title: String
    var series: String
    var isPlaying: Bool
    var elapsed: Double
    var duration: Double
    var rate: Float
    var hasNext: Bool
    var hasPrevious: Bool
    /// Human label such as "12 min" or "End of discourse"; nil when no timer is set.
    var sleepTimerLabel: String?
}

/// One row in a Watch or CarPlay list. `id` is opaque to the Watch and is sent
/// back unchanged in `playItem`; the phone resolves it against current state.
struct CompanionRow: Codable, Equatable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case discourse, bookmark, series }

    var id: String
    var kind: Kind
    var title: String
    var subtitle: String
    /// Listened fraction 0...1 for discourses with saved progress.
    var progress: Double?
    var isCurrent: Bool
    /// Discourse rows: whether the file is already on the Watch.
    var isOnWatch: Bool

    init(
        id: String, kind: Kind, title: String, subtitle: String,
        progress: Double? = nil, isCurrent: Bool = false, isOnWatch: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.progress = progress
        self.isCurrent = isCurrent
        self.isOnWatch = isOnWatch
    }
}

enum CompanionLocation: Codable, Equatable, Hashable, Sendable {
    case continueListening
    case downloads
    /// Downloaded discourses of one series; the value is a series row id.
    case series(String)
    case bookmarks
}

struct CompanionPage: Codable, Equatable, Sendable {
    var location: CompanionLocation
    var title: String
    var rows: [CompanionRow]
    /// True when the phone omitted rows to stay within the payload bound.
    var isTruncated: Bool
    /// Shown instead of rows when the page is empty.
    var emptyMessage: String
}

struct CompanionSnapshot: Codable, Equatable, Sendable {
    var version: Int = CompanionWire.version
    /// Identifies one phone process; sequences only order snapshots within it.
    var sessionID: UUID
    var sequence: UInt64
    var nowPlaying: CompanionNowPlaying?
    /// `AccentTheme` raw value ("blue", "teal", ...), so the Watch matches the phone.
    var accentName: String?
    /// The phone's listening for discourses stored on the Watch, so a saved talk
    /// resumes where the phone left off rather than where the Watch last stopped.
    var savedPositions: [CompanionSavedPosition]?
}

struct CompanionSavedPosition: Codable, Equatable, Hashable, Sendable {
    var discourseID: String
    /// 0 when the phone finished or cleared the discourse.
    var position: Double
    var finished: Bool
    /// When the phone last moved this position, by the phone's clock.
    var savedAt: Date
}

enum CompanionAction: Codable, Equatable, Sendable {
    case snapshot
    case browse(CompanionLocation)
    /// The play state the listener chose, not a toggle: a late or repeated
    /// delivery leaves the phone in that state instead of flipping it back.
    case setPlaying(Bool)
    case skipForward
    case skipBackward
    case nextDiscourse
    case previousDiscourse
    case setRate(Float)
    /// Plays a discourse or bookmark row from a page the Watch displayed.
    case playItem(rowID: String)
    /// Asks the phone to transfer a downloaded discourse's audio to the Watch.
    case sendToWatch(discourseID: String)

    /// Reads never change phone state and may be retried; everything else is
    /// sent once and never retried automatically.
    var isReadOnly: Bool {
        switch self {
        case .snapshot, .browse: return true
        default: return false
        }
    }
}

struct CompanionRequest: Codable, Equatable, Sendable {
    var version: Int = CompanionWire.version
    var id: UUID
    var action: CompanionAction
    /// Transport actions carry the discourse the Watch showed, so a tap made
    /// against stale state is rejected instead of applied to another talk.
    var expectedDiscourseID: String?
    /// Discourse ids stored on the Watch, so pages can mark `isOnWatch`.
    var watchInventory: [String]?
}

struct CompanionResponse: Codable, Equatable, Sendable {
    var version: Int = CompanionWire.version
    var requestID: UUID
    var snapshot: CompanionSnapshot
    var page: CompanionPage?
    /// Listener-facing reason when the action was not performed.
    var errorMessage: String?
}

/// Sent Watch -> phone with `transferUserInfo` after offline listening, so the
/// phone's saved position and Continue Listening reflect it.
struct CompanionPositionReport: Codable, Equatable, Sendable {
    var discourseID: String
    var position: Double
    var duration: Double
    var finished: Bool
    var recordedAt: Date
}

/// Metadata attached to an offline audio file sent phone -> Watch.
struct CompanionOfflineFile: Codable, Equatable, Sendable {
    var discourseID: String
    var title: String
    var series: String
    var resumePosition: Double
    var duration: Double
    /// When the phone last moved `resumePosition`; nil when it never played the talk.
    var resumeSavedAt: Date?
}
