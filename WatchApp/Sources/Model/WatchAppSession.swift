import Foundation

/// Process-owned objects, so view recreation never replaces the WCSession delegate or the player.
@MainActor
final class WatchAppSession {
    static let shared = WatchAppSession()

    let model: WatchCompanionModel
    let offline: OfflineLibrary
    let player: OfflinePlayer
    #if DEBUG
    let fixture: WatchFixtureMode?
    #endif
    private let transport: WatchConnectivityTransport?

    private init() {
        #if DEBUG
        if let fixture = WatchFixtureMode(arguments: ProcessInfo.processInfo.arguments) {
            let parts = WatchDebugFixtures.make(fixture)
            self.fixture = fixture
            transport = nil
            offline = parts.offline
            player = OfflinePlayer(library: parts.offline, reporter: PositionReporter { _ in true })
            model = parts.model
            Self.wire(model: model, offline: offline, reporter: nil)
            return
        }
        fixture = nil
        #endif
        let store = OfflineFileStore()
        let transport = WatchConnectivityTransport(offlineStore: store)
        let client = WatchRequestClient(transport: transport)
        let offline = OfflineLibrary(store: store)
        let reporter = PositionReporter { [weak client] data in client?.transferUserInfo(data) ?? false }
        self.transport = transport
        self.offline = offline
        player = OfflinePlayer(library: offline, reporter: reporter)
        model = WatchCompanionModel(client: client, inventory: { [weak offline] in offline?.inventory ?? [] })
        Self.wire(model: model, offline: offline, reporter: reporter)
    }

    static func wire(model: WatchCompanionModel, offline: OfflineLibrary, reporter: PositionReporter?) {
        model.onOfflineEvent = { [weak offline] event in offline?.receive(event) }
        model.onSavedPositions = { [weak offline] positions in offline?.adoptPhonePositions(positions) }
        model.onSessionActivated = { [weak reporter] in reporter?.flush() }
        model.start()
    }

    func receiveBackgroundUpdates() async {
        model.start()
        await transport?.finishBackgroundDelivery()
    }
}
