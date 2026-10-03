import Foundation
@testable import OshoDiscoursesWatch

@MainActor
final class TestClock {
    private var manual: TimeInterval = 100
    private let live: Bool

    /// A live clock follows the real monotonic clock for tests that wait on real tasks.
    init(live: Bool = false) { self.live = live }

    var now: TimeInterval { live ? WatchClock.now : manual }
    func advance(_ seconds: TimeInterval) { manual += seconds }
}

@MainActor
final class TestTransport: WatchTransport {
    struct Sent {
        let data: Data
        let completion: @Sendable (Result<Data, WatchTransportFailure>) -> Void
    }

    var state: WatchConnectionState = .ready(reachable: true, installed: true, needsUnlock: false)
    var onEvent: (@MainActor (WatchTransportEvent) -> Void)?
    private(set) var sent: [Sent] = []
    private(set) var userInfos: [Data] = []
    var acceptsUserInfo = true
    var automaticResponse: ((CompanionRequest) -> CompanionResponse?)?

    var requests: [CompanionRequest] {
        sent.compactMap { try? CompanionWire.decode(CompanionRequest.self, from: $0.data) }
    }

    func activate() { onEvent?(.stateChanged(state)) }
    func refreshState() { onEvent?(.stateChanged(state)) }

    func send(_ data: Data, completion: @escaping @Sendable (Result<Data, WatchTransportFailure>) -> Void) {
        sent.append(Sent(data: data, completion: completion))
        if let request = try? CompanionWire.decode(CompanionRequest.self, from: data),
           let response = automaticResponse?(request) {
            completion(.success(try! CompanionWire.encode(response)))
        }
    }

    func transferUserInfo(_ data: Data) -> Bool {
        guard acceptsUserInfo else { return false }
        userInfos.append(data)
        return true
    }

    func reply(at index: Int, snapshot: CompanionSnapshot, page: CompanionPage? = nil, error: String? = nil) {
        let request = requests[index]
        let response = CompanionResponse(requestID: request.id, snapshot: snapshot, page: page, errorMessage: error)
        sent[index].completion(.success(try! CompanionWire.encode(response)))
    }

    func replyRaw(at index: Int, _ data: Data) { sent[index].completion(.success(data)) }
    func fail(at index: Int, _ failure: WatchTransportFailure = .deliveryFailed) { sent[index].completion(.failure(failure)) }

    func setState(_ newState: WatchConnectionState) {
        state = newState
        onEvent?(.stateChanged(newState))
    }
}

enum Fixtures {
    static let sessionA = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!
    static let sessionB = UUID(uuidString: "BBBBBBBB-0000-4000-8000-000000000002")!

    static func nowPlaying(
        id: String = "mustard-seed-3", playing: Bool = true, elapsed: Double = 42,
        duration: Double = 5_400, rate: Float = 1
    ) -> CompanionNowPlaying {
        CompanionNowPlaying(
            discourseID: id, title: "The Mustard Seed #3", series: "The Mustard Seed", isPlaying: playing,
            elapsed: elapsed, duration: duration, rate: rate, hasNext: true, hasPrevious: true, sleepTimerLabel: nil
        )
    }

    static func snapshot(
        session: UUID = sessionA, sequence: UInt64 = 1, playing: Bool = true, elapsed: Double = 42,
        rate: Float = 1, id: String = "mustard-seed-3", accent: String? = nil, empty: Bool = false,
        saved: [CompanionSavedPosition]? = nil
    ) -> CompanionSnapshot {
        CompanionSnapshot(
            sessionID: session, sequence: sequence,
            nowPlaying: empty ? nil : nowPlaying(id: id, playing: playing, elapsed: elapsed, rate: rate),
            accentName: accent, savedPositions: saved
        )
    }

    /// A fixed base time, so stamps compare and round-trip exactly.
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func saved(_ id: String, _ position: Double, at seconds: TimeInterval, finished: Bool = false) -> CompanionSavedPosition {
        CompanionSavedPosition(discourseID: id, position: position, finished: finished, savedAt: t0 + seconds)
    }

    static func offlineFile(_ id: String, resume: Double, duration: Double = 600, savedAt: Date? = nil) -> CompanionOfflineFile {
        CompanionOfflineFile(discourseID: id, title: "The Mustard Seed #3", series: "The Mustard Seed",
                             resumePosition: resume, duration: duration, resumeSavedAt: savedAt)
    }

    /// An offline store in its own temporary directory, never the app's.
    static func temporaryStore() throws -> (store: OfflineFileStore, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OfflineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (OfflineFileStore(directory: root.appendingPathComponent("Offline")), root)
    }

    @discardableResult
    static func receive(_ file: CompanionOfflineFile, into store: OfflineFileStore, scratch: URL) throws -> OfflineEntry {
        let source = scratch.appendingPathComponent("inbox-\(UUID().uuidString).mp3")
        try Data(repeating: 7, count: 512).write(to: source)
        return try store.receive(fileAt: source, file: file)
    }

    static func response(for request: CompanionRequest, snapshot: CompanionSnapshot, page: CompanionPage? = nil,
                         error: String? = nil) -> CompanionResponse {
        CompanionResponse(requestID: request.id, snapshot: snapshot, page: page, errorMessage: error)
    }

    static func request(_ action: CompanionAction, expected: String? = nil) -> CompanionRequest {
        CompanionRequest(id: UUID(), action: action, expectedDiscourseID: expected, watchInventory: [])
    }

    static func isolatedDefaults() -> UserDefaults {
        let name = "osho.watch.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}

@MainActor
func waitUntil(timeout: Duration = .seconds(2), _ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw WaitTimeout() }
        try await Task.sleep(for: .milliseconds(5))
    }
}

struct WaitTimeout: Error {}

/// Deadline that never fires on its own, so tests drive timeouts explicitly.
let neverDeadline: @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(3_600)) }
