import Foundation

#if canImport(WatchConnectivity) && !targetEnvironment(macCatalyst)
import Observation
import OSLog

/// Phone end of the Watch companion: answers requests, publishes Now Playing through
/// application context, sends offline audio and merges positions the Watch reports.
@MainActor
final class WatchPhoneSession {
    static let shared = WatchPhoneSession()
    static let positionPublicationInterval: TimeInterval = 10
    /// Lets a deliberate paired-simulator test run real WatchConnectivity inside an XCTest host.
    static let testOptInEnvironmentKey = "OSHO_WATCH_SESSION_IN_TESTS"

    private(set) var transfers: WatchTransferService?
    private(set) var handler: CompanionRequestHandler?
    private var transport: (any WatchPhoneTransport)?
    private var merger: WatchPositionMerger?
    private var clock: @MainActor () -> TimeInterval = { WatchPhoneClock.now }
    private var scheduler: any WatchScheduling = WatchTaskScheduler()
    private var observe: (@MainActor (@escaping @MainActor () -> Void) -> Void)?

    private var started = false
    private var lastPublished: CompanionSnapshot?
    private var lastAttemptAt: TimeInterval?
    private var contextNeedsRetry = false
    private var cancelTrailing: (@MainActor () -> Void)?

    /// Context publications attempted; for tests.
    private(set) var publicationAttempts = 0

    init() {}

    /// Idempotent. Call from `App.init` after `AppRuntime.start()`.
    func start(runtime: AppRuntime) {
        guard !started else { return }
        let isTestHost = NSClassFromString("XCTestCase") != nil
            && ProcessInfo.processInfo.environment[Self.testOptInEnvironmentKey] != "1"
        let transport: any WatchPhoneTransport = isTestHost ? WatchInertTransport() : WatchConnectivityTransport()
        let playback = WatchRuntimePlayback(runtime: runtime)
        let transfers = WatchTransferService(
            sink: transport,
            library: WatchRuntimeTransferLibrary(
                downloads: runtime.downloadService, playbackState: runtime.playbackState, player: runtime.audioPlayer
            )
        )
        let player = runtime.audioPlayer
        configure(
            transport: transport,
            handler: CompanionRequestHandler(surface: playback, transfers: transfers),
            transfers: transfers,
            merger: WatchPositionMerger(
                playbackState: runtime.playbackState,
                loaded: { [weak player] in
                    guard let player, let id = player.currentTrackId else { return nil }
                    let session = player.playSession.flatMap { $0.discourseID == id ? $0 : nil }
                    return .init(
                        discourseID: id, isPlaying: player.isPlaying, playingSince: session?.startedAt,
                        resumedFrom: session?.startPosition, savedBeforeResume: session?.savedBefore
                    )
                },
                // With history, so the player offers a way back to where the phone was.
                moveLoadedPlayer: { [weak player] position in player?.seekWithHistory(to: position) },
                unloadLoadedPlayer: { [weak player] in
                    guard let player, !player.isPlaying else { return }
                    player.stop()
                }
            ),
            observe: { onChange in Self.observeRuntime(player: player, onChange) }
        )
    }

    /// Test seam: wires injected collaborators and starts.
    func configure(
        transport: any WatchPhoneTransport,
        handler: CompanionRequestHandler,
        transfers: WatchTransferService?,
        merger: WatchPositionMerger?,
        clock: @escaping @MainActor () -> TimeInterval = { WatchPhoneClock.now },
        scheduler: any WatchScheduling = WatchTaskScheduler(),
        observe: (@MainActor (@escaping @MainActor () -> Void) -> Void)? = nil
    ) {
        guard !started else { return }
        started = true
        self.transport = transport
        self.handler = handler
        self.transfers = transfers
        self.merger = merger
        self.clock = clock
        self.scheduler = scheduler
        self.observe = observe
        transport.onEvent = { [weak self] event in self?.receive(event) }
        observe? { [weak self] in self?.snapshotDidChange() }
        transport.activate()
        transfers?.refresh()
    }

    // MARK: Events

    private func receive(_ event: WatchTransportEvent) {
        switch event {
        case .stateChanged(let state):
            Logger.watchSession.info("link \(state.logLabel, privacy: .public)")
            transfers?.refresh()
            if !state.canPublish {
                cancelTrailingPublication()
                lastPublished = nil
                lastAttemptAt = nil
            }
            snapshotDidChange()
        case .request(let data, let reply):
            handle(data, reply: reply)
        case .positionReport(let data):
            merger?.apply(data)
        case .fileTransferFinished(let discourseID, let fileURL, let succeeded):
            transfers?.transferFinished(discourseID: discourseID, fileURL: fileURL, succeeded: succeeded)
        }
    }

    func handle(_ data: Data, reply: WatchReply) {
        guard let handler, reply.canHandle(at: clock()) else {
            reply.finish(Data())
            return
        }
        // Malformed or oversized input gets an empty reply: without a request id nothing can be correlated.
        guard let request = try? CompanionWire.decode(CompanionRequest.self, from: data) else {
            Logger.watchSession.info("request malformed")
            reply.finish(Data())
            return
        }
        // Recheck after decoding so an expired request never starts a playback change.
        guard reply.canHandle(at: clock()) else {
            reply.finish(Data())
            return
        }
        let response = handler.handle(request)
        let encoded = (try? CompanionWire.encode(response))
            ?? (try? CompanionWire.encode(handler.rejection(request, "This list is too long to show on Apple Watch.")))
        reply.finish(encoded ?? Data())
        snapshotDidChange()
    }

    // MARK: Publication

    /// Semantic changes publish at once, even while unreachable; position-only changes publish
    /// at most every 10 s and only while the Watch is reachable, with one trailing update.
    func snapshotDidChange() {
        guard started, let handler, let transport, transport.linkState.canPublish else { return }
        let snapshot = handler.snapshot()
        guard snapshot != lastPublished || contextNeedsRetry else { return }
        let semantic = lastPublished.map { !Self.sameSemantics(snapshot, $0) } ?? true
        if !semantic {
            guard transport.linkState.isReachable else { return }
            let now = clock()
            if let lastAttemptAt, now < lastAttemptAt + Self.positionPublicationInterval {
                scheduleTrailingPublication(after: lastAttemptAt + Self.positionPublicationInterval - now)
                return
            }
        }
        cancelTrailingPublication()
        lastAttemptAt = clock()
        publicationAttempts += 1
        do {
            try transport.updateApplicationContext(try CompanionWire.encode(snapshot))
            lastPublished = snapshot
            contextNeedsRetry = false
        } catch {
            contextNeedsRetry = true
            scheduleTrailingPublication(after: Self.positionPublicationInterval)
        }
    }

    private func scheduleTrailingPublication(after seconds: TimeInterval) {
        guard cancelTrailing == nil else { return }
        cancelTrailing = scheduler.schedule(after: seconds) { [weak self] in
            guard let self else { return }
            cancelTrailing = nil
            snapshotDidChange()
        }
    }

    private func cancelTrailingPublication() {
        cancelTrailing?()
        cancelTrailing = nil
    }

    /// Saved positions move like the clock: pause, finish and track changes are
    /// semantic anyway and carry the newest ones.
    static func sameSemantics(_ lhs: CompanionSnapshot, _ rhs: CompanionSnapshot) -> Bool {
        guard lhs.sessionID == rhs.sessionID, lhs.accentName == rhs.accentName else { return false }
        switch (lhs.nowPlaying, rhs.nowPlaying) {
        case (nil, nil): return true
        case (.some(var lhs), .some(var rhs)):
            lhs.elapsed = 0
            rhs.elapsed = 0
            return lhs == rhs
        default: return false
        }
    }

    // MARK: Runtime observation

    private static func observeRuntime(player: AudioPlayerService, _ onChange: @escaping @MainActor () -> Void) {
        withObservationTracking {
            _ = player.currentTrackId
            _ = player.currentTitle
            _ = player.isPlaying
            _ = player.playbackRate
            _ = player.currentTime
            _ = player.duration
            _ = player.queue.count
            _ = player.currentIndex
            _ = SleepTimerService.shared.mode
            _ = SleepTimerService.shared.remainingTime
            _ = UserSettings.shared.effectiveAccentTheme
        } onChange: { [weak player] in
            // Fires in willSet; the hop lets the new value land before the snapshot reads it.
            Task { @MainActor [weak player] in
                guard let player else { return }
                onChange()
                observeRuntime(player: player, onChange)
            }
        }
    }
}
#else
/// Catalyst has no Apple Watch pairing; the entry point exists so app startup stays unconditional.
@MainActor
final class WatchPhoneSession {
    static let shared = WatchPhoneSession()
    func start(runtime: AppRuntime) {}
}
#endif
