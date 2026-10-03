#if canImport(WatchConnectivity) && !targetEnvironment(macCatalyst)
import Foundation
import OSLog
import WatchConnectivity

enum WatchPhoneClock {
    private static let origin = ContinuousClock.now

    // Continuous time includes suspension, so a request held while the phone slept still expires.
    static var now: TimeInterval {
        let elapsed = origin.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }
}

extension Logger {
    static let watchSession = Logger(subsystem: "com.agraabhi.oshodiscourses", category: "WatchSession")
}

enum WatchLinkState: Equatable, Sendable {
    case unsupported
    case activating
    case inactive
    case failed
    case ready(paired: Bool, installed: Bool, reachable: Bool)

    /// Application context and file transfers queue for a paired Watch with the app installed.
    var canPublish: Bool {
        if case .ready(let paired, let installed, _) = self { return paired && installed }
        return false
    }

    var isReachable: Bool {
        if case .ready(let paired, let installed, let reachable) = self { return paired && installed && reachable }
        return false
    }

    var logLabel: String {
        switch self {
        case .unsupported: return "unsupported"
        case .activating: return "activating"
        case .inactive: return "inactive"
        case .failed: return "failed"
        case .ready(let paired, let installed, let reachable):
            if !paired { return "notPaired" }
            if !installed { return "notInstalled" }
            return reachable ? "reachable" : "unreachable"
        }
    }
}

enum WatchTransportEvent: Sendable {
    case stateChanged(WatchLinkState)
    case request(Data, WatchReply)
    case positionReport(Data)
    /// `discourseID` is nil when the finished transfer's metadata could not be read.
    case fileTransferFinished(discourseID: String?, fileURL: URL, succeeded: Bool)
}

/// The phone's WatchConnectivity surface; tests replace it with an in-memory fake.
@MainActor
protocol WatchPhoneTransport: WatchFileTransferSink {
    var onEvent: (@MainActor (WatchTransportEvent) -> Void)? { get set }
    func activate()
    func updateApplicationContext(_ data: Data) throws
}

/// The part of the transport that file transfers need.
@MainActor
protocol WatchFileTransferSink: AnyObject {
    var linkState: WatchLinkState { get }
    func transferFile(_ url: URL, metadata: Data) throws
    /// Discourse ids of transfers still queued or in flight, including ones from earlier launches.
    func outstandingTransferDiscourseIDs() -> Set<String>
}

enum WatchTransportFailure: Error, Equatable, Sendable {
    case unavailable
    case oversized
}

/// Schedules a main-actor callback; returns a cancel closure. Injected so tests control time.
@MainActor
protocol WatchScheduling {
    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> @MainActor () -> Void
}

struct WatchTaskScheduler: WatchScheduling {
    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        let task = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            action()
        }
        return { task.cancel() }
    }
}

// WCSession's reply block is not Sendable. The lock hands its single invocation to whichever of
// the deadline and the main-actor handler gets there first.
final class WatchReply: @unchecked Sendable {
    static let deadline: TimeInterval = 6

    private let lock = NSLock()
    private var handler: ((Data) -> Void)?
    let receivedAt: TimeInterval

    init(receivedAt: TimeInterval = WatchPhoneClock.now, handler: @escaping (Data) -> Void) {
        self.receivedAt = receivedAt
        self.handler = handler
    }

    func canHandle(at now: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return handler != nil && now >= receivedAt && now - receivedAt < Self.deadline
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return handler == nil
    }

    func finish(_ data: Data) {
        lock.lock()
        let reply = handler
        handler = nil
        lock.unlock()
        reply?(data)
    }

    func scheduleDeadline() {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.deadline) { [self] in
            finish(Data())
        }
    }
}

/// Inert transport for XCTest launches, so the test host never activates the user's real session.
@MainActor
final class WatchInertTransport: WatchPhoneTransport {
    var onEvent: (@MainActor (WatchTransportEvent) -> Void)?
    var linkState: WatchLinkState { .unsupported }
    func activate() {}
    func updateApplicationContext(_ data: Data) throws { throw WatchTransportFailure.unavailable }
    func transferFile(_ url: URL, metadata: Data) throws { throw WatchTransportFailure.unavailable }
    func outstandingTransferDiscourseIDs() -> Set<String> { [] }
}

@MainActor
final class WatchConnectivityTransport: WatchPhoneTransport {
    private(set) var linkState: WatchLinkState = .activating
    var onEvent: (@MainActor (WatchTransportEvent) -> Void)?

    private let session: WCSession?
    private let delegate: WatchConnectivityDelegate
    private var eventTask: Task<Void, Never>?
    private var activationRequested = false

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: WatchTransportEvent.self)
        delegate = WatchConnectivityDelegate(events: continuation)
        session = WCSession.isSupported() ? WCSession.default : nil
        if session == nil { linkState = .unsupported }
        session?.delegate = delegate
        // One consumer keeps the delegate queue's order without moving WCSession or [String: Any] across actors.
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                receive(event)
            }
        }
    }

    deinit { eventTask?.cancel() }

    func activate() {
        guard let session else {
            publish(.unsupported)
            return
        }
        if session.activationState == .activated {
            publish(WatchConnectivityDelegate.state(of: session))
        } else if !activationRequested {
            activationRequested = true
            publish(.activating)
            session.activate()
        }
    }

    func updateApplicationContext(_ data: Data) throws {
        guard data.count <= CompanionWire.maximumPayloadBytes else { throw WatchTransportFailure.oversized }
        guard let session, session.activationState == .activated, linkState.canPublish else {
            throw WatchTransportFailure.unavailable
        }
        try session.updateApplicationContext([CompanionWire.snapshotContextKey: data])
    }

    func transferFile(_ url: URL, metadata: Data) throws {
        guard let session, session.activationState == .activated, linkState.canPublish else {
            throw WatchTransportFailure.unavailable
        }
        _ = session.transferFile(url, metadata: [CompanionWire.offlineFileMetadataKey: metadata])
    }

    func outstandingTransferDiscourseIDs() -> Set<String> {
        guard let session, session.activationState == .activated else { return [] }
        return Set(session.outstandingFileTransfers.compactMap {
            WatchConnectivityDelegate.discourseID(in: $0.file.metadata)
        })
    }

    private func receive(_ event: WatchTransportEvent) {
        if case .stateChanged(let state) = event {
            if state != .activating { activationRequested = false }
            linkState = state
        }
        onEvent?(event)
    }

    private func publish(_ state: WatchLinkState) {
        linkState = state
        onEvent?(.stateChanged(state))
    }
}

private final class WatchConnectivityDelegate: NSObject, WCSessionDelegate {
    private let events: AsyncStream<WatchTransportEvent>.Continuation

    init(events: AsyncStream<WatchTransportEvent>.Continuation) {
        self.events = events
        super.init()
    }

    deinit { events.finish() }

    nonisolated static func state(of session: WCSession) -> WatchLinkState {
        switch session.activationState {
        case .notActivated: return .activating
        case .inactive: return .inactive
        case .activated:
            return .ready(paired: session.isPaired, installed: session.isWatchAppInstalled, reachable: session.isReachable)
        @unknown default: return .failed
        }
    }

    nonisolated static func discourseID(in metadata: [String: Any]?) -> String? {
        guard let data = metadata?[CompanionWire.offlineFileMetadataKey] as? Data,
              let file = try? CompanionWire.decode(CompanionOfflineFile.self, from: data) else { return nil }
        return file.discourseID
    }

    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?
    ) {
        events.yield(.stateChanged(error == nil && activationState == .activated ? Self.state(of: session) : .failed))
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        events.yield(.stateChanged(Self.state(of: session)))
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        events.yield(.stateChanged(Self.state(of: session)))
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        events.yield(.stateChanged(.inactive))
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Watch switching: the session must be reactivated for the newly selected Watch.
        events.yield(.stateChanged(.activating))
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data, replyHandler: @escaping (Data) -> Void) {
        guard messageData.count <= CompanionWire.maximumPayloadBytes else {
            replyHandler(Data())
            return
        }
        let reply = WatchReply(handler: replyHandler)
        reply.scheduleDeadline()
        events.yield(.request(messageData, reply))
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let data = userInfo[CompanionWire.positionReportKey] as? Data,
              data.count <= CompanionWire.maximumPayloadBytes else { return }
        events.yield(.positionReport(data))
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: (any Error)?) {
        events.yield(.fileTransferFinished(
            discourseID: Self.discourseID(in: fileTransfer.file.metadata),
            fileURL: fileTransfer.file.fileURL, succeeded: error == nil
        ))
    }
}
#endif
