import Foundation
import OSLog
import WatchConnectivity

@MainActor
final class WatchConnectivityTransport: WatchTransport {
    private(set) var state: WatchConnectionState = .activating
    var onEvent: (@MainActor (WatchTransportEvent) -> Void)?

    private let session: WCSession?
    private let delegate: WatchConnectivityDelegate
    private var eventTask: Task<Void, Never>?
    private var activationRequested = false

    init(offlineStore: OfflineFileStore) {
        let (stream, continuation) = AsyncStream.makeStream(of: WatchTransportEvent.self)
        delegate = WatchConnectivityDelegate(events: continuation, offlineStore: offlineStore)
        session = WCSession.isSupported() ? WCSession.default : nil
        if session == nil { state = .unsupported }
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
            refreshState()
        } else if !activationRequested {
            activationRequested = true
            publish(.activating)
            session.activate()
        }
    }

    func refreshState() {
        guard let session else { return }
        publish(WatchConnectivityDelegate.state(of: session))
    }

    func send(_ data: Data, completion: @escaping @Sendable (Result<Data, WatchTransportFailure>) -> Void) {
        guard data.count <= CompanionWire.maximumPayloadBytes else {
            completion(.failure(.oversized))
            return
        }
        guard let session, session.activationState == .activated, session.isReachable else {
            completion(.failure(.unreachable))
            return
        }
        WatchConnectivityDelegate.send(data, using: session, completion: completion)
    }

    func transferUserInfo(_ data: Data) -> Bool {
        guard data.count <= CompanionWire.maximumPayloadBytes,
              let session, session.activationState == .activated else { return false }
        _ = session.transferUserInfo([CompanionWire.positionReportKey: data])
        return true
    }

    /// Background refresh: wait for queued files and context to drain through the delegate before returning.
    func finishBackgroundDelivery() async {
        guard let session else { return }
        activate()
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !Task.isCancelled, ContinuousClock.now < deadline {
            if session.activationState == .activated, !session.hasContentPending {
                if let data = session.receivedApplicationContext[CompanionWire.snapshotContextKey] as? Data,
                   data.count <= CompanionWire.maximumPayloadBytes {
                    onEvent?(.applicationContext(data))
                }
                return
            }
            if state == .failed { return }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
    }

    private func receive(_ event: WatchTransportEvent) {
        if case .stateChanged(let newState) = event {
            if newState != .activating { activationRequested = false }
            state = newState
        }
        onEvent?(event)
    }

    private func publish(_ newState: WatchConnectionState) {
        state = newState
        onEvent?(.stateChanged(newState))
    }
}

private final class WatchConnectivityDelegate: NSObject, WCSessionDelegate {
    private let events: AsyncStream<WatchTransportEvent>.Continuation
    private let offlineStore: OfflineFileStore

    init(events: AsyncStream<WatchTransportEvent>.Continuation, offlineStore: OfflineFileStore) {
        self.events = events
        self.offlineStore = offlineStore
        super.init()
    }

    deinit { events.finish() }

    // SDK reply blocks are not Sendable and must not inherit the caller's main-actor isolation.
    nonisolated static func send(
        _ data: Data,
        using session: WCSession,
        completion: @escaping @Sendable (Result<Data, WatchTransportFailure>) -> Void
    ) {
        session.sendMessageData(data) { reply in
            completion(reply.count <= CompanionWire.maximumPayloadBytes ? .success(reply) : .failure(.oversized))
        } errorHandler: { _ in
            completion(.failure(.deliveryFailed))
        }
    }

    nonisolated static func state(of session: WCSession) -> WatchConnectionState {
        switch session.activationState {
        case .notActivated: return .activating
        case .inactive: return .inactive
        case .activated:
            return .ready(
                reachable: session.isReachable, installed: session.isCompanionAppInstalled,
                needsUnlock: session.iOSDeviceNeedsUnlockAfterRebootForReachability
            )
        @unknown default: return .failed
        }
    }

    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?
    ) {
        events.yield(.stateChanged(error == nil && activationState == .activated ? Self.state(of: session) : .failed))
        if activationState == .activated,
           let data = session.receivedApplicationContext[CompanionWire.snapshotContextKey] as? Data,
           data.count <= CompanionWire.maximumPayloadBytes {
            events.yield(.applicationContext(data))
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        events.yield(.stateChanged(Self.state(of: session)))
    }

    nonisolated func sessionCompanionAppInstalledDidChange(_ session: WCSession) {
        events.yield(.stateChanged(Self.state(of: session)))
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[CompanionWire.snapshotContextKey] as? Data,
              data.count <= CompanionWire.maximumPayloadBytes else { return }
        events.yield(.applicationContext(data))
    }

    // The system deletes the file when this returns, so the move must finish synchronously here.
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let metadata = file.metadata?[CompanionWire.offlineFileMetadataKey] as? Data
        do {
            let entry = try offlineStore.receive(fileAt: file.fileURL, metadata: metadata)
            events.yield(.offlineFileStored(entry))
        } catch {
            Logger.watchOffline.error("offline file rejected")
            events.yield(.offlineFileRejected)
        }
    }
}
