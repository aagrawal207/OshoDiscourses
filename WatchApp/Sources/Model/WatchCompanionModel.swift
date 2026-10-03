import Foundation
import Observation
import OSLog

/// iPhone remote: browsing, transport controls and Save to Watch requests. Playback state changes
/// only when the phone replies; a tap never flips the display optimistically.
@MainActor @Observable
final class WatchCompanionModel {
    private(set) var connection: WatchConnectionState = .activating
    private(set) var timeline = WatchSnapshotState()
    private(set) var pendingCommand: CompanionRequest?
    private(set) var isRefreshing = false
    private(set) var needsReconciliation = false
    private(set) var notice: String?
    private(set) var pages: [CompanionLocation: CompanionPage] = [:]
    private(set) var loadingPages: Set<CompanionLocation> = []
    private(set) var pageErrors: [CompanionLocation: String] = [:]
    private(set) var contentRevision: UInt64 = 0
    private(set) var isForeground = false
    private(set) var accent: WatchAccent
    /// Discourses the phone agreed to send during this launch, by id, with their titles.
    /// The watch cannot observe the phone's outgoing transfers, so these stay pending until the file lands.
    private(set) var requestedTransfers: [String: String] = [:]

    @ObservationIgnored private let client: WatchRequestClient
    @ObservationIgnored private let accentStore: WatchAccentStore
    @ObservationIgnored private let uptime: @MainActor () -> TimeInterval
    @ObservationIgnored private let inventory: @MainActor () -> [String]
    @ObservationIgnored private let heartbeatInterval: Duration
    @ObservationIgnored private var started = false
    @ObservationIgnored private var lifecycle = UUID()
    @ObservationIgnored private var refreshID: UUID?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var pageRequestIDs: [CompanionLocation: UUID] = [:]
    @ObservationIgnored private var pageRevisions: [CompanionLocation: UInt64] = [:]
    @ObservationIgnored private var pendingWasDispatched = false
    /// Called when the session becomes able to queue transfers, so held position reports can go.
    @ObservationIgnored var onSessionActivated: (@MainActor () -> Void)?
    @ObservationIgnored var onOfflineEvent: (@MainActor (WatchTransportEvent) -> Void)?
    /// Phone progress for talks stored on the Watch, from every snapshot that arrives. Each entry carries
    /// its own `savedAt`, so it needs none of the session or sequence ordering the display does.
    @ObservationIgnored var onSavedPositions: (@MainActor ([CompanionSavedPosition]) -> Void)?

    static let heartbeat: Duration = .seconds(12)

    init(
        client: WatchRequestClient,
        uptime: @escaping @MainActor () -> TimeInterval = { WatchClock.now },
        accentStore: WatchAccentStore = WatchAccentStore(),
        heartbeatInterval: Duration = WatchCompanionModel.heartbeat,
        inventory: @escaping @MainActor () -> [String] = { [] }
    ) {
        self.client = client
        self.uptime = uptime
        self.accentStore = accentStore
        self.heartbeatInterval = heartbeatInterval
        self.inventory = inventory
        accent = accentStore.load()
    }

    var nowPlaying: CompanionNowPlaying? { timeline.snapshot?.nowPlaying }
    var isCurrent: Bool { timeline.isCurrent(at: uptime()) }
    var isPlaying: Bool { timeline.isPlaying(at: uptime()) }
    var position: Double { timeline.position(at: uptime()) }
    var canChooseItem: Bool { isCurrent && !needsReconciliation && pendingCommand == nil }
    var canControl: Bool { canChooseItem && nowPlaying != nil }

    func start() {
        guard !started else { return }
        started = true
        client.onStateChange = { [weak self] state in self?.connectionChanged(state) }
        client.onSnapshot = { [weak self] snapshot in self?.receiveContext(snapshot) }
        client.onPhoneSnapshot = { [weak self] snapshot in
            guard let positions = snapshot.savedPositions, !positions.isEmpty else { return }
            self?.onSavedPositions?(positions)
        }
        client.onOfflineEvent = { [weak self] event in self?.receiveOffline(event) }
        client.start()
    }

    func setForeground(_ foreground: Bool) {
        start()
        guard foreground != isForeground else { return }
        isForeground = foreground
        lifecycle = UUID()
        timeline.setAvailability(reachable: connection.canMessage, foreground: foreground, at: uptime())
        heartbeatTask?.cancel()
        heartbeatTask = nil
        if foreground {
            contentRevision &+= 1
            client.refreshConnection()
            scheduleRefresh()
            let interval = heartbeatInterval
            heartbeatTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: interval) } catch { return }
                    guard let self, isForeground else { return }
                    await refresh()
                }
            }
        } else {
            if pendingCommand != nil, pendingWasDispatched { markUncertain() }
            pendingCommand = nil
            pendingWasDispatched = false
            refreshID = nil
            isRefreshing = false
            refreshTask?.cancel()
            refreshTask = nil
            pageRequestIDs.removeAll()
            loadingPages.removeAll()
            client.cancelAll()
        }
    }

    // MARK: Reads

    func refresh() async {
        guard isForeground, !isRefreshing else { return }
        client.refreshConnection()
        guard connection.canMessage else { return }
        let request = makeRequest(.snapshot)
        let lifecycle = self.lifecycle
        refreshID = request.id
        isRefreshing = true
        defer {
            if refreshID == request.id {
                refreshID = nil
                isRefreshing = false
            }
        }
        do {
            let response = try await client.send(request)
            guard lifecycle == self.lifecycle, isForeground, refreshID == request.id else { return }
            let wasUncertain = needsReconciliation
            guard accept(response.snapshot) else { return }
            if wasUncertain {
                notice = "Updated from iPhone. Check the player before trying again."
            } else if let error = response.errorMessage {
                notice = error
            }
        } catch is CancellationError {
        } catch {
            guard lifecycle == self.lifecycle, isForeground, refreshID == request.id else { return }
            timeline.invalidate(at: uptime())
            if !needsReconciliation, connection.canMessage {
                notice = "Couldn't reach Osho Talks on iPhone. Open it there, then try again."
            }
        }
    }

    func loadPage(_ location: CompanionLocation, force: Bool = false) async {
        guard isForeground else { return }
        guard connection.canMessage else {
            if pages[location] == nil { pageErrors[location] = nil }
            return
        }
        guard pageRequestIDs[location] == nil else { return }
        if !force, pages[location] != nil, pageRevisions[location] == contentRevision { return }
        let request = makeRequest(.browse(location))
        let lifecycle = self.lifecycle
        pageRequestIDs[location] = request.id
        loadingPages.insert(location)
        pageErrors[location] = nil
        defer {
            if pageRequestIDs[location] == request.id {
                pageRequestIDs[location] = nil
                loadingPages.remove(location)
            }
        }
        do {
            let response = try await client.send(request)
            guard lifecycle == self.lifecycle, isForeground, pageRequestIDs[location] == request.id else { return }
            guard accept(response.snapshot) else {
                pageErrors[location] = "Your iPhone restarted Osho Talks. Refresh this page."
                return
            }
            guard let page = response.page, page.location == location,
                  Set(page.rows.map(\.id)).count == page.rows.count else {
                pageErrors[location] = response.errorMessage ?? "This list couldn't load. Try again."
                return
            }
            pages[location] = page
            pageRevisions[location] = contentRevision
        } catch is CancellationError {
        } catch {
            guard lifecycle == self.lifecycle, pageRequestIDs[location] == request.id else { return }
            pageErrors[location] = "Couldn't load this list from iPhone."
        }
    }

    // MARK: Mutations

    /// Transport controls carry the discourse the watch showed, so the phone rejects a stale tap.
    @discardableResult
    func command(_ action: CompanionAction, displayed: CompanionSnapshot) async -> Bool {
        guard !action.isReadOnly, displayed.nowPlaying != nil else { return false }
        guard let current = timeline.snapshot, Self.matches(action, displayed: displayed, current: current) else {
            notice = Self.staleMessage
            return false
        }
        return await mutate(action, expectedDiscourseID: displayed.nowPlaying?.discourseID, displayed: displayed) != nil
    }

    @discardableResult
    func play(_ row: CompanionRow) async -> Bool {
        guard row.kind != .series else { return false }
        return await mutate(.playItem(rowID: row.id), expectedDiscourseID: nil, displayed: nil) != nil
    }

    @discardableResult
    func saveToWatch(discourseID: String, title: String) async -> Bool {
        guard await mutate(.sendToWatch(discourseID: discourseID), expectedDiscourseID: nil, displayed: nil) != nil else {
            return false
        }
        if !inventory().contains(discourseID) { requestedTransfers[discourseID] = title }
        return true
    }

    func dismissNotice() { notice = nil }

    // MARK: Copy

    var connectionTitle: String {
        switch connection {
        case .unsupported: "iPhone not available"
        case .activating: "Connecting to iPhone…"
        case .inactive, .failed: "Open Osho Talks on iPhone"
        case .ready(_, false, _): "Install Osho Talks on iPhone"
        case .ready(_, _, true): "Unlock your iPhone"
        case .ready(false, _, _): "Open Osho Talks on iPhone"
        case .ready(true, _, _): isCurrent ? "On iPhone" : "Checking iPhone…"
        }
    }

    var connectionDetail: String {
        switch connection {
        case .ready(_, false, _): "This app browses and plays talks from Osho Talks on your iPhone."
        case .ready(_, _, true): "Unlock it once after restarting, then open Osho Talks."
        case .ready(false, _, _), .inactive, .failed:
            "Keep your iPhone nearby to browse and control talks."
        case .unsupported: "Talks saved on Apple Watch still play."
        case .activating, .ready(true, _, _): "Talks play on your iPhone. Controls update when it replies."
        }
    }

    var canRetryConnection: Bool {
        switch connection {
        case .inactive, .failed: true
        case .ready(let reachable, let installed, let needsUnlock): installed && !needsUnlock && !reachable
        default: false
        }
    }

    var connectionSymbol: String {
        connection.canMessage ? "iphone" : "iphone.slash"
    }

    static let staleMessage = "The talk changed on iPhone. Check it before trying again."

    // MARK: Private

    static func matches(_ action: CompanionAction, displayed: CompanionSnapshot, current: CompanionSnapshot) -> Bool {
        guard displayed.sessionID == current.sessionID,
              displayed.nowPlaying?.discourseID == current.nowPlaying?.discourseID else { return false }
        if case .setPlaying = action {
            return displayed.nowPlaying?.isPlaying == current.nowPlaying?.isPlaying
        }
        return true
    }

    private func makeRequest(_ action: CompanionAction, expectedDiscourseID: String? = nil) -> CompanionRequest {
        CompanionRequest(id: UUID(), action: action, expectedDiscourseID: expectedDiscourseID, watchInventory: inventory())
    }

    private func mutate(
        _ action: CompanionAction, expectedDiscourseID: String?, displayed: CompanionSnapshot?
    ) async -> CompanionResponse? {
        guard canChooseItem else {
            if needsReconciliation { notice = "Checking iPhone before sending another action." }
            return nil
        }
        let request = makeRequest(action, expectedDiscourseID: expectedDiscourseID)
        let lifecycle = self.lifecycle
        pendingCommand = request
        pendingWasDispatched = false
        notice = nil
        defer {
            if pendingCommand?.id == request.id {
                pendingCommand = nil
                pendingWasDispatched = false
            }
        }
        do {
            let response = try await client.send(request) { [weak self] in
                guard let self, lifecycle == self.lifecycle, isForeground, pendingCommand?.id == request.id,
                      !needsReconciliation else { return false }
                if let displayed {
                    guard let current = timeline.snapshot,
                          Self.matches(action, displayed: displayed, current: current) else { return false }
                }
                pendingWasDispatched = true
                return true
            }
            guard lifecycle == self.lifecycle, isForeground, pendingCommand?.id == request.id else { return nil }
            guard accept(response.snapshot) else {
                markUncertain()
                scheduleRefresh()
                return nil
            }
            if let error = response.errorMessage {
                notice = error
                return nil
            }
            contentRevision &+= 1
            return response
        } catch let error as WatchRequestError {
            guard lifecycle == self.lifecycle, pendingCommand?.id == request.id else { return nil }
            if pendingWasDispatched, error.leavesOutcomeUnknown {
                markUncertain()
                scheduleRefresh()
                return nil
            }
            switch error {
            case .busy: notice = "Still waiting for iPhone. Try again in a moment."
            case .unreachable:
                timeline.invalidate(at: uptime())
                notice = "Open Osho Talks on iPhone, then try again."
            case .staleContext:
                notice = Self.staleMessage
                scheduleRefresh()
            case .unsupportedVersion: notice = "Update Osho Talks on iPhone and Apple Watch."
            default: notice = "Couldn't reach iPhone. Try again."
            }
            return nil
        } catch {
            guard lifecycle == self.lifecycle, pendingCommand?.id == request.id else { return nil }
            if pendingWasDispatched {
                // WCSession cannot recall a dispatched command, so a cancelled one may still have run.
                markUncertain()
                scheduleRefresh()
            }
            return nil
        }
    }

    private func connectionChanged(_ state: WatchConnectionState) {
        let wasReachable = connection.canMessage
        let wasActivated = connection.isActivated
        connection = state
        timeline.setAvailability(reachable: state.canMessage, foreground: isForeground, at: uptime())
        if wasReachable, !state.canMessage, pendingCommand != nil, pendingWasDispatched { markUncertain() }
        if state.canMessage, !wasReachable {
            contentRevision &+= 1
            scheduleRefresh()
        }
        if state.isActivated, !wasActivated { onSessionActivated?() }
    }

    private func receiveContext(_ snapshot: CompanionSnapshot) {
        let previousSession = timeline.snapshot?.sessionID
        if timeline.receive(snapshot, source: .applicationContext, at: uptime()) { applyAccent(of: snapshot) }
        if previousSession != nil, previousSession != snapshot.sessionID { scheduleRefresh() }
    }

    private func receiveOffline(_ event: WatchTransportEvent) {
        if case .offlineFileStored(let entry) = event { requestedTransfers[entry.discourseID] = nil }
        onOfflineEvent?(event)
    }

    private func accept(_ snapshot: CompanionSnapshot) -> Bool {
        let previousSession = timeline.snapshot?.sessionID
        if timeline.receive(snapshot, source: .reply, at: uptime()) { applyAccent(of: snapshot) }
        guard timeline.snapshot?.sessionID == snapshot.sessionID, isCurrent else { return false }
        needsReconciliation = false
        if previousSession != snapshot.sessionID {
            pages.removeAll()
            pageRevisions.removeAll()
            contentRevision &+= 1
        }
        return true
    }

    // Only snapshots the timeline accepted may restyle the app, so a retired phone process cannot.
    private func applyAccent(of snapshot: CompanionSnapshot) {
        if let applied = accentStore.apply(snapshot.accentName), applied != accent { accent = applied }
    }

    private func markUncertain() {
        guard !needsReconciliation else { return }
        Logger.watchLink.info("command outcome unknown; refreshing")
        needsReconciliation = true
        timeline.invalidate(at: uptime())
        notice = "No reply from iPhone. Checking what's playing before you try again."
        pendingCommand = nil
        pendingWasDispatched = false
        refreshID = nil
        isRefreshing = false
        refreshTask?.cancel()
        refreshTask = nil
        pageRequestIDs.removeAll()
        loadingPages.removeAll()
        client.cancelAll()
    }

    private func scheduleRefresh() {
        guard isForeground, connection.canMessage else { return }
        refreshTask = Task { [weak self] in await self?.refresh() }
    }
}
