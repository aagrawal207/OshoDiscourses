#if canImport(WatchConnectivity) && !targetEnvironment(macCatalyst)
import Foundation
import OSLog

/// Everything a Watch request may read or change on the phone. The runtime wraps
/// `AppRuntime`; tests supply a fake so fixtures stay out of the user's stores.
@MainActor
protocol WatchPlaybackSurface: AnyObject {
    var currentDiscourseID: String? { get }
    var hasNext: Bool { get }
    var accentName: String? { get }
    func nowPlaying() -> CompanionNowPlaying?
    func savedPositions(for discourseIDs: Set<String>) -> [CompanionSavedPosition]
    func page(for location: CompanionLocation, watchInventory: Set<String>, maximumRows: Int) -> CompanionPage
    func setPlaying(_ playing: Bool)
    func skipForward(_ seconds: TimeInterval)
    func skipBackward(_ seconds: TimeInterval)
    func nextDiscourse()
    func previousDiscourse()
    func setRate(_ rate: Float)
    func playDiscourse(_ discourseID: String) throws(PlaybackLauncher.Failure)
    func playBookmark(_ bookmarkID: String) throws(PlaybackLauncher.Failure)
}

@MainActor
final class WatchRuntimePlayback: WatchPlaybackSurface {
    private let runtime: AppRuntime

    init(runtime: AppRuntime) { self.runtime = runtime }

    private var player: AudioPlayerService { runtime.audioPlayer }

    var currentDiscourseID: String? { player.currentTrackId }
    var hasNext: Bool { player.hasNext }
    var accentName: String? { UserSettings.shared.effectiveAccentTheme.rawValue }
    func nowPlaying() -> CompanionNowPlaying? {
        guard var nowPlaying = runtime.library.nowPlaying() else { return nil }
        // The phone's "m:ss" countdown would make every second a semantic change; the Watch shows minutes.
        nowPlaying.sleepTimerLabel = Self.sleepTimerLabel(SleepTimerService.shared)
        return nowPlaying
    }

    static func sleepTimerLabel(_ timer: SleepTimerService) -> String? {
        switch timer.mode {
        case .off: return nil
        case .endOfDiscourse: return "End of discourse"
        case .countdown: return "\(max(1, Int((timer.remainingTime / 60).rounded(.up)))) min"
        }
    }
    func page(for location: CompanionLocation, watchInventory: Set<String>, maximumRows: Int) -> CompanionPage {
        runtime.library.page(for: location, watchInventory: watchInventory, maximumRows: maximumRows)
    }

    /// Stored values only: a playing talk's live clock would change every tick, and
    /// pausing saves the exact position first.
    func savedPositions(for discourseIDs: Set<String>) -> [CompanionSavedPosition] {
        let state = runtime.playbackState
        let positions: [CompanionSavedPosition] = discourseIDs.compactMap { id in
            guard let savedAt = state.lastSaved(discourseId: id) else { return nil }
            let position = state.getPosition(discourseId: id)
            return CompanionSavedPosition(
                discourseID: id, position: position, finished: position == 0 && state.isCompleted(id), savedAt: savedAt
            )
        }
        return Array(positions.sorted { $0.savedAt > $1.savedAt }.prefix(CompanionRequestHandler.maximumSavedPositions))
    }
    func setPlaying(_ playing: Bool) { player.setPlaying(playing) }
    func skipForward(_ seconds: TimeInterval) { player.skipForward(seconds) }
    func skipBackward(_ seconds: TimeInterval) { player.skipBackward(seconds) }
    func nextDiscourse() { player.skipToNext() }
    func previousDiscourse() { player.skipToPrevious() }
    func setRate(_ rate: Float) { player.setRate(rate) }
    func playDiscourse(_ discourseID: String) throws(PlaybackLauncher.Failure) { try runtime.launcher.playDiscourse(discourseID) }
    func playBookmark(_ bookmarkID: String) throws(PlaybackLauncher.Failure) { try runtime.launcher.playBookmark(id: bookmarkID) }
}

/// Executes decoded Watch requests against phone state. Synchronous on the main actor,
/// so a request observes and changes one consistent state.
@MainActor
final class CompanionRequestHandler {
    static let skipForwardSeconds: TimeInterval = 30
    static let skipBackwardSeconds: TimeInterval = 15
    static let receiptCapacity = 64
    static let maximumBrowseRows = 60
    static let maximumSavedPositions = 100
    /// Leaves room for the reply envelope the transport adds around our bytes.
    static let payloadBudget = CompanionWire.maximumPayloadBytes - 1024

    let sessionID: UUID
    private let surface: any WatchPlaybackSurface
    private let transfers: WatchTransferService?
    private var sequence: UInt64 = 0
    private var lastContent: SnapshotContent?
    private var receipts: [UUID: Receipt] = [:]
    private var receiptOrder: [UUID] = []

    /// How many requests actually ran (cached replays excluded); for tests and logs.
    private(set) var executedCount = 0

    init(surface: any WatchPlaybackSurface, transfers: WatchTransferService?, sessionID: UUID = UUID()) {
        self.surface = surface
        self.transfers = transfers
        self.sessionID = sessionID
    }

    // MARK: Snapshot

    /// Sequence advances only when content changes, so equal snapshots compare equal.
    func snapshot() -> CompanionSnapshot {
        let inventory = transfers?.inventorySet ?? []
        let content = SnapshotContent(
            nowPlaying: surface.nowPlaying(), accentName: surface.accentName,
            savedPositions: inventory.isEmpty ? nil : surface.savedPositions(for: inventory)
        )
        if content != lastContent {
            lastContent = content
            sequence += 1
        }
        return CompanionSnapshot(
            sessionID: sessionID, sequence: sequence, nowPlaying: content.nowPlaying, accentName: content.accentName,
            savedPositions: content.savedPositions
        )
    }

    // MARK: Requests

    func handle(_ request: CompanionRequest) -> CompanionResponse {
        guard request.version == CompanionWire.version else {
            log(request.action, "unsupportedVersion")
            return rejection(request, "Update Osho Talks on iPhone and Apple Watch to the same version.")
        }
        if let receipt = receipts[request.id] {
            guard receipt.action == request.action, receipt.expectedDiscourseID == request.expectedDiscourseID else {
                log(request.action, "reusedID")
                return rejection(request, "This request was already used. Try again.")
            }
            log(request.action, "replayed")
            return receipt.response
        }
        if let inventory = request.watchInventory { transfers?.updateInventory(inventory) }

        executedCount += 1
        let response: CompanionResponse
        do {
            let page = try perform(request)
            response = bounded(CompanionResponse(requestID: request.id, snapshot: snapshot(), page: page))
            log(request.action, "ok")
        } catch {
            response = rejection(request, error.message)
            log(request.action, error.logLabel)
        }
        receipts[request.id] = Receipt(action: request.action, expectedDiscourseID: request.expectedDiscourseID, response: response)
        receiptOrder.append(request.id)
        if receiptOrder.count > Self.receiptCapacity { receipts[receiptOrder.removeFirst()] = nil }
        return response
    }

    /// Correlated rejection for a decoded request; never cached, never executed.
    func rejection(_ request: CompanionRequest, _ message: String) -> CompanionResponse {
        CompanionResponse(requestID: request.id, snapshot: snapshot(), page: nil, errorMessage: message)
    }

    private func perform(_ request: CompanionRequest) throws(Failure) -> CompanionPage? {
        switch request.action {
        case .snapshot:
            return nil
        case .browse(let location):
            let inventory = request.watchInventory.map(Set.init) ?? transfers?.inventorySet ?? []
            return surface.page(for: location, watchInventory: inventory, maximumRows: Self.maximumBrowseRows)
        case .playItem(let rowID):
            switch CompanionLibrary.resolve(rowID) {
            case .discourse(let id):
                do { try surface.playDiscourse(id) } catch { throw .launch(error) }
            case .bookmark(let id):
                do { try surface.playBookmark(id) } catch { throw .launch(error) }
            case .series, nil:
                throw .notPlayable
            }
            return nil
        case .sendToWatch(let discourseID):
            guard let transfers else { throw .transfer(.unavailable) }
            do { _ = try transfers.send(discourseID) } catch { throw .transfer(error) }
            return nil
        case .setPlaying, .skipForward, .skipBackward, .nextDiscourse, .previousDiscourse, .setRate:
            break
        }

        guard let current = surface.currentDiscourseID else { throw .nothingLoaded }
        guard let expected = request.expectedDiscourseID, expected == current else { throw .staleDiscourse }
        switch request.action {
        case .setPlaying(let playing): surface.setPlaying(playing)
        case .skipForward: surface.skipForward(Self.skipForwardSeconds)
        case .skipBackward: surface.skipBackward(Self.skipBackwardSeconds)
        case .nextDiscourse:
            guard surface.hasNext else { throw .noNext }
            surface.nextDiscourse()
        case .previousDiscourse: surface.previousDiscourse()
        case .setRate(let rate):
            guard rate.isFinite else { throw .invalidRate }
            surface.setRate(min(2, max(0.5, rate)))
        default: break
        }
        return nil
    }

    /// Keeps the encoded reply inside the payload bound: shortens row text first, then drops rows.
    func bounded(_ response: CompanionResponse) -> CompanionResponse {
        guard var page = response.page, encodedSize(response) > Self.payloadBudget else { return response }
        var result = response
        page.rows = page.rows.map { row in
            var row = row
            row.title = Self.shortened(row.title, to: 80)
            row.subtitle = Self.shortened(row.subtitle, to: 60)
            return row
        }
        result.page = page
        while encodedSize(result) > Self.payloadBudget, !page.rows.isEmpty {
            page.rows.removeLast(max(1, page.rows.count / 10))
            page.isTruncated = true
            result.page = page
        }
        return result
    }

    private func encodedSize(_ response: CompanionResponse) -> Int {
        (try? JSONEncoder().encode(response).count) ?? Int.max
    }

    private static func shortened(_ text: String, to length: Int) -> String {
        text.count <= length ? text : String(text.prefix(length - 1)) + "…"
    }

    private func log(_ action: CompanionAction, _ outcome: String) {
        Logger.watchSession.info("request \(Self.kind(action), privacy: .public) \(outcome, privacy: .public)")
    }

    static func kind(_ action: CompanionAction) -> String {
        switch action {
        case .snapshot: return "snapshot"
        case .browse: return "browse"
        case .setPlaying: return "setPlaying"
        case .skipForward: return "skipForward"
        case .skipBackward: return "skipBackward"
        case .nextDiscourse: return "nextDiscourse"
        case .previousDiscourse: return "previousDiscourse"
        case .setRate: return "setRate"
        case .playItem: return "playItem"
        case .sendToWatch: return "sendToWatch"
        }
    }

    private struct SnapshotContent: Equatable {
        let nowPlaying: CompanionNowPlaying?
        let accentName: String?
        let savedPositions: [CompanionSavedPosition]?
    }

    private struct Receipt {
        let action: CompanionAction
        let expectedDiscourseID: String?
        let response: CompanionResponse
    }

    enum Failure: Error, Equatable {
        case nothingLoaded
        case staleDiscourse
        case noNext
        case invalidRate
        case notPlayable
        case launch(PlaybackLauncher.Failure)
        case transfer(WatchTransferService.Failure)

        var message: String {
            switch self {
            case .nothingLoaded: return "Nothing is playing on iPhone. Choose a discourse first."
            case .staleDiscourse: return "iPhone is playing a different discourse now. Check Now Playing and try again."
            case .noNext: return "This is the last downloaded discourse in the series."
            case .invalidRate: return "That speed isn't available."
            case .notPlayable: return "Choose a discourse or bookmark to play."
            case .launch(let failure): return failure.message
            case .transfer(let failure): return failure.message
            }
        }

        var logLabel: String {
            switch self {
            case .nothingLoaded: return "nothingLoaded"
            case .staleDiscourse: return "staleDiscourse"
            case .noNext: return "noNext"
            case .invalidRate: return "invalidRate"
            case .notPlayable: return "notPlayable"
            case .launch: return "launchFailed"
            case .transfer(let failure): return "transfer.\(failure.logLabel)"
            }
        }
    }
}
#endif
