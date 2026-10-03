import Foundation
import OSLog

extension Logger {
    static let watchLink = Logger(subsystem: "com.agraabhi.oshodiscourses", category: "WatchLink")
    static let watchOffline = Logger(subsystem: "com.agraabhi.oshodiscourses", category: "WatchOffline")
}

enum WatchClock {
    private static let origin = ContinuousClock.now

    // Continuous time includes suspension, so a reply that arrives after the watch slept still counts as late.
    static var now: TimeInterval {
        let elapsed = origin.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }
}

enum WatchConnectionState: Equatable, Sendable {
    case unsupported
    case activating
    case inactive
    case failed
    case ready(reachable: Bool, installed: Bool, needsUnlock: Bool)

    var canMessage: Bool {
        if case .ready(let reachable, let installed, _) = self { return reachable && installed }
        return false
    }

    var isActivated: Bool {
        if case .ready = self { return true }
        return false
    }
}

enum WatchTransportFailure: Error, Equatable, Sendable {
    case unreachable
    case deliveryFailed
    case oversized
}

enum WatchTransportEvent: Sendable {
    case stateChanged(WatchConnectionState)
    case applicationContext(Data)
    /// The file was already moved into the offline store inside the delegate callback.
    case offlineFileStored(OfflineEntry)
    case offlineFileRejected
}

@MainActor
protocol WatchTransport: AnyObject {
    var state: WatchConnectionState { get }
    var onEvent: (@MainActor (WatchTransportEvent) -> Void)? { get set }
    func activate()
    func refreshState()
    func send(_ data: Data, completion: @escaping @Sendable (Result<Data, WatchTransportFailure>) -> Void)
    /// Queues background delivery to the phone; false when the session cannot accept it yet.
    func transferUserInfo(_ data: Data) -> Bool
}
