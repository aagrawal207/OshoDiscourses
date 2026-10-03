import Foundation

enum WatchRequestError: Error, Equatable, Sendable {
    case unreachable
    case busy
    case timedOut
    case connectionChanged
    case invalidReply
    case mismatchedReply
    case unsupportedVersion
    case deliveryFailed
    case oversized
    case staleContext

    /// Failures after which a dispatched mutation may or may not have run on the phone.
    var leavesOutcomeUnknown: Bool {
        switch self {
        case .timedOut, .connectionChanged, .invalidReply, .mismatchedReply, .deliveryFailed, .unsupportedVersion: true
        case .unreachable, .busy, .oversized, .staleContext: false
        }
    }
}

/// Correlates WatchConnectivity replies with requests. Reads may overlap; mutations are one at a time
/// and are never retried here, because WCSession cannot say whether a failed send reached the phone.
@MainActor
final class WatchRequestClient {
    nonisolated static let replyDeadline: TimeInterval = 8
    nonisolated static let maximumConcurrentRequests = 4

    private struct Pending {
        let request: CompanionRequest
        let generation: UUID
        let continuation: CheckedContinuation<CompanionResponse, any Error>
        let deadline: Task<Void, Never>
        let expiresAt: TimeInterval
    }

    private let transport: any WatchTransport
    private let waitForDeadline: @Sendable () async throws -> Void
    private let uptime: @MainActor () -> TimeInterval
    private var pending: [UUID: Pending] = [:]
    private var generation = UUID()
    private var started = false

    private(set) var state: WatchConnectionState
    var onStateChange: (@MainActor (WatchConnectionState) -> Void)?
    var onSnapshot: (@MainActor (CompanionSnapshot) -> Void)?
    /// Every snapshot the phone delivers, reply or context, before any ordering or lifecycle filter.
    var onPhoneSnapshot: (@MainActor (CompanionSnapshot) -> Void)?
    var onOfflineEvent: (@MainActor (WatchTransportEvent) -> Void)?

    init(
        transport: any WatchTransport,
        waitForDeadline: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: .seconds(WatchRequestClient.replyDeadline))
        },
        uptime: @escaping @MainActor () -> TimeInterval = { WatchClock.now }
    ) {
        self.transport = transport
        self.waitForDeadline = waitForDeadline
        self.uptime = uptime
        state = transport.state
    }

    var hasMutationInFlight: Bool { pending.values.contains { !$0.request.action.isReadOnly } }
    var inFlightCount: Int { pending.count }

    func start() {
        guard !started else { return }
        started = true
        transport.onEvent = { [weak self] event in self?.receive(event) }
        transport.activate()
        state = transport.state
        onStateChange?(state)
    }

    func refreshConnection() {
        transport.activate()
        transport.refreshState()
    }

    func transferUserInfo(_ data: Data) -> Bool { transport.transferUserInfo(data) }

    /// `onDispatch` runs synchronously just before the bytes leave; returning false cancels the send.
    func send(
        _ request: CompanionRequest,
        onDispatch: @MainActor () -> Bool = { true }
    ) async throws -> CompanionResponse {
        try Task.checkCancellation()
        guard request.version == CompanionWire.version else { throw WatchRequestError.unsupportedVersion }
        let data: Data
        do { data = try CompanionWire.encode(request) } catch { throw WatchRequestError.oversized }
        guard state.canMessage, transport.state.canMessage else { throw WatchRequestError.unreachable }
        guard pending.count < Self.maximumConcurrentRequests, pending[request.id] == nil else {
            throw WatchRequestError.busy
        }
        if !request.action.isReadOnly, hasMutationInFlight { throw WatchRequestError.busy }

        let generation = self.generation
        let response: CompanionResponse = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard onDispatch() else {
                    continuation.resume(throwing: WatchRequestError.staleContext)
                    return
                }
                let deadline = Task { [weak self, waitForDeadline] in
                    do { try await waitForDeadline() } catch { return }
                    self?.finish(request.id, generation: generation, result: .failure(WatchRequestError.timedOut))
                }
                pending[request.id] = Pending(
                    request: request, generation: generation, continuation: continuation,
                    deadline: deadline, expiresAt: uptime() + Self.replyDeadline
                )
                transport.send(data) { [weak self] result in
                    Task { @MainActor [weak self] in
                        self?.receiveReply(result, id: request.id, generation: generation)
                    }
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.finish(request.id, generation: generation, result: .failure(CancellationError()))
            }
        }
        return response
    }

    func cancelAll() {
        retirePending(with: CancellationError())
    }

    private func receive(_ event: WatchTransportEvent) {
        switch event {
        case .stateChanged(let newState):
            if state.canMessage, !newState.canMessage {
                retirePending(with: WatchRequestError.connectionChanged)
            }
            state = newState
            onStateChange?(newState)
        case .applicationContext(let data):
            guard let snapshot = try? CompanionWire.decode(CompanionSnapshot.self, from: data),
                  snapshot.version == CompanionWire.version else { return }
            onPhoneSnapshot?(snapshot)
            onSnapshot?(snapshot)
        case .offlineFileStored, .offlineFileRejected:
            onOfflineEvent?(event)
        }
    }

    private func receiveReply(_ result: Result<Data, WatchTransportFailure>, id: UUID, generation: UUID) {
        guard let entry = pending[id], entry.generation == generation else { return }
        // The deadline task may not have been scheduled yet; the clock decides.
        guard uptime() < entry.expiresAt else {
            finish(id, generation: generation, result: .failure(WatchRequestError.timedOut))
            return
        }
        switch result {
        case .failure(let failure):
            // Unreachable is reported before sending; the request was already size-checked, so oversized means the reply.
            let error: WatchRequestError = switch failure {
            case .unreachable: .unreachable
            case .oversized: .invalidReply
            case .deliveryFailed: .deliveryFailed
            }
            finish(id, generation: generation, result: .failure(error))
        case .success(let data):
            guard let response = try? CompanionWire.decode(CompanionResponse.self, from: data) else {
                finish(id, generation: generation, result: .failure(WatchRequestError.invalidReply))
                return
            }
            guard response.version == CompanionWire.version, response.snapshot.version == CompanionWire.version else {
                finish(id, generation: generation, result: .failure(WatchRequestError.unsupportedVersion))
                return
            }
            guard response.requestID == id else {
                finish(id, generation: generation, result: .failure(WatchRequestError.mismatchedReply))
                return
            }
            onPhoneSnapshot?(response.snapshot)
            finish(id, generation: generation, result: .success(response))
        }
    }

    private func finish(_ id: UUID, generation: UUID, result: Result<CompanionResponse, any Error>) {
        guard let entry = pending[id], entry.generation == generation else { return }
        pending.removeValue(forKey: id)
        entry.deadline.cancel()
        entry.continuation.resume(with: result)
    }

    private func retirePending(with error: any Error) {
        generation = UUID()
        let retired = pending.values
        pending.removeAll()
        for entry in retired {
            entry.deadline.cancel()
            entry.continuation.resume(throwing: error)
        }
    }
}
