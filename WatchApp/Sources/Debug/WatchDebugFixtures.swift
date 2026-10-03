#if DEBUG
import Foundation

/// `--watch-fixture <mode>` runs the app against an in-memory phone and a throwaway offline store.
enum WatchFixtureMode: String, CaseIterable {
    case playing, paused, empty, disconnected, offline

    init?(arguments: [String]) {
        guard let flag = arguments.firstIndex(of: "--watch-fixture"), arguments.indices.contains(flag + 1),
              let mode = WatchFixtureMode(rawValue: arguments[flag + 1]) else { return nil }
        self = mode
    }

    /// Screen the fixture opens on; `--watch-route home` keeps the root list.
    func initialRoute(arguments: [String]) -> WatchRoute? {
        if let flag = arguments.firstIndex(of: "--watch-route"), arguments.indices.contains(flag + 1) {
            switch arguments[flag + 1] {
            case "home": return nil
            case "player": return .remotePlayer
            case "offline": return .offline
            case "local": return .localPlayer
            case "continue": return .page(.continueListening)
            case "downloads": return .page(.downloads)
            case "bookmarks": return .page(.bookmarks)
            default: break
            }
        }
        switch self {
        case .playing, .paused: return .remotePlayer
        case .offline: return .offline
        case .empty, .disconnected: return nil
        }
    }
}

@MainActor
enum WatchDebugFixtures {
    static func make(_ mode: WatchFixtureMode) -> (model: WatchCompanionModel, offline: OfflineLibrary) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OshoWatchFixture-\(mode.rawValue)", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        let store = OfflineFileStore(directory: directory.appendingPathComponent("Offline", isDirectory: true))
        let seeds: Int = switch mode {
        case .offline: 3
        case .disconnected: 2
        case .playing, .paused: 1
        case .empty: 0
        }
        // Watch copies were saved a day ago; the fixture phone has listened since (see `Talk.phoneSaved`).
        let copiedAt = Date().addingTimeInterval(-86_400)
        for talk in talks.prefix(seeds) {
            seed(talk, into: store, scratch: directory, position: talk.watchPosition,
                 savedAt: talk.watchPosition > 0 ? copiedAt : nil)
        }
        let offline = OfflineLibrary(store: store)
        let transport = WatchFixtureTransport(mode: mode, store: store, scratch: directory)
        let defaults = UserDefaults(suiteName: "osho.watch.fixture") ?? .standard
        defaults.removePersistentDomain(forName: "osho.watch.fixture")
        let model = WatchCompanionModel(
            client: WatchRequestClient(transport: transport),
            accentStore: WatchAccentStore(defaults: defaults),
            inventory: { [weak offline] in offline?.inventory ?? [] }
        )
        return (model, offline)
    }

    struct Talk {
        let id: String
        let title: String
        let series: String
        let duration: Double
        /// Where the fixture phone is; at the duration means finished there.
        let position: Double
        /// How long ago the phone last moved it; nil when never played there.
        let phoneSavedAgo: TimeInterval?
        /// Where the Watch copy was left when saved, before the phone's later listening.
        let watchPosition: Double
    }

    static let talks: [Talk] = [
        Talk(id: "the-mustard-seed-3", title: "The Mustard Seed #3", series: "The Mustard Seed",
             duration: 5_412, position: 1_830, phoneSavedAgo: 3_600, watchPosition: 1_200),
        Talk(id: "tao-the-three-treasures-7", title: "Tao: The Three Treasures #7",
             series: "Tao: The Three Treasures", duration: 6_120, position: 0, phoneSavedAgo: nil, watchPosition: 0),
        Talk(id: "ek-omkar-satnam-4", title: "Ek Omkar Satnam #4", series: "Ek Omkar Satnam",
             duration: 4_980, position: 4_980, phoneSavedAgo: 7_200, watchPosition: 3_000),
        Talk(id: "the-book-of-secrets-12", title: "The Book of Secrets #12", series: "The Book of Secrets",
             duration: 5_760, position: 600, phoneSavedAgo: 259_200, watchPosition: 600),
        Talk(id: "zen-the-path-of-paradox-2", title: "Zen: The Path of Paradox #2",
             series: "Zen: The Path of Paradox", duration: 5_220, position: 0, phoneSavedAgo: nil, watchPosition: 0),
    ]

    static func seed(_ talk: Talk, into store: OfflineFileStore, scratch: URL, position: Double, savedAt: Date?) {
        let file = scratch.appendingPathComponent(UUID().uuidString + ".wav")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try? silentWAV(seconds: 90).write(to: file)
        _ = try? store.receive(fileAt: file, file: CompanionOfflineFile(
            discourseID: talk.id, title: talk.title, series: talk.series,
            resumePosition: position, duration: talk.duration, resumeSavedAt: savedAt
        ))
    }

    static func silentWAV(seconds: Int) -> Data {
        let sampleRate: UInt32 = 8_000
        let samples = Data(count: Int(sampleRate) * seconds * 2)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + samples.count))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(sampleRate); append(sampleRate * 2); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(samples.count))
        data.append(samples)
        return data
    }
}

@MainActor
private final class WatchFixtureTransport: WatchTransport {
    var state: WatchConnectionState = .activating
    var onEvent: (@MainActor (WatchTransportEvent) -> Void)?

    private let mode: WatchFixtureMode
    private let store: OfflineFileStore
    private let scratch: URL
    private let sessionID = UUID(uuidString: "0540DA7A-0000-4000-8000-00000000F1C5")!
    private var sequence: UInt64 = 1
    private var activated = false
    private var talkIndex = 0
    private var hasTalk: Bool
    private var isPlaying: Bool
    private var position: Double
    private var rate: Float = 1
    private var lastClock = WatchClock.now
    /// The phone's saved listening per talk, as `CompanionSnapshot.savedPositions` reports it.
    private var phoneSaves: [String: CompanionSavedPosition]
    private let accentName: String = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--watch-accent"), arguments.indices.contains(flag + 1) else {
            return "orange"
        }
        return arguments[flag + 1]
    }()

    init(mode: WatchFixtureMode, store: OfflineFileStore, scratch: URL) {
        self.mode = mode
        self.store = store
        self.scratch = scratch
        hasTalk = mode != .empty
        isPlaying = mode == .playing
        position = WatchDebugFixtures.talks[0].position
        let now = Date()
        phoneSaves = Dictionary(uniqueKeysWithValues: WatchDebugFixtures.talks.compactMap { talk in
            talk.phoneSavedAgo.map { ago in
                let finished = talk.position >= talk.duration
                return (talk.id, CompanionSavedPosition(
                    discourseID: talk.id, position: finished ? 0 : talk.position, finished: finished,
                    savedAt: now.addingTimeInterval(-ago)
                ))
            }
        })
    }

    func activate() {
        guard !activated else { return }
        activated = true
        state = .ready(reachable: mode != .disconnected && mode != .offline, installed: true, needsUnlock: false)
        onEvent?(.stateChanged(state))
        if let data = try? CompanionWire.encode(snapshot) { onEvent?(.applicationContext(data)) }
    }

    func refreshState() { onEvent?(.stateChanged(state)) }

    func transferUserInfo(_ data: Data) -> Bool { true }

    func send(_ data: Data, completion: @escaping @Sendable (Result<Data, WatchTransportFailure>) -> Void) {
        guard state.canMessage, let request = try? CompanionWire.decode(CompanionRequest.self, from: data) else {
            completion(.failure(.unreachable))
            return
        }
        advance()
        var page: CompanionPage?
        var error: String?
        if let expected = request.expectedDiscourseID, expected != currentTalk?.id {
            error = "The talk changed on iPhone. Check it before trying again."
        } else {
            switch request.action {
            case .snapshot: break
            case .browse(let location): page = makePage(location, inventory: Set(request.watchInventory ?? []))
            case .setPlaying(let playing): isPlaying = playing
            case .skipForward: position = min(position + 30, currentTalk?.duration ?? 0); recordPhoneMove()
            case .skipBackward: position = max(0, position - 15); recordPhoneMove()
            case .nextDiscourse: move(by: 1)
            case .previousDiscourse: move(by: -1)
            case .setRate(let value): rate = value
            case .playItem(let rowID):
                let id = rowID.hasPrefix("b:") ? String(rowID.dropFirst(2)).components(separatedBy: "@")[0]
                    : String(rowID.dropFirst(2))
                if let index = WatchDebugFixtures.talks.firstIndex(where: { $0.id == id }) {
                    talkIndex = index
                    hasTalk = true
                    isPlaying = true
                    position = phoneSaves[id].map { $0.finished ? 0 : $0.position } ?? 0
                    recordPhoneMove()
                } else {
                    error = "That talk isn't downloaded on iPhone."
                }
            case .sendToWatch(let discourseID): deliverLater(discourseID)
            }
        }
        sequence += 1
        let response = CompanionResponse(requestID: request.id, snapshot: snapshot, page: page, errorMessage: error)
        let reply = try? CompanionWire.encode(response)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            if let reply { completion(.success(reply)) } else { completion(.failure(.deliveryFailed)) }
        }
    }

    private var currentTalk: WatchDebugFixtures.Talk? {
        hasTalk ? WatchDebugFixtures.talks[talkIndex] : nil
    }

    private var snapshot: CompanionSnapshot {
        let talk = currentTalk
        return CompanionSnapshot(
            sessionID: sessionID, sequence: sequence,
            nowPlaying: talk.map {
                CompanionNowPlaying(
                    discourseID: $0.id, title: $0.title, series: $0.series, isPlaying: isPlaying,
                    elapsed: position, duration: $0.duration, rate: rate,
                    hasNext: talkIndex < WatchDebugFixtures.talks.count - 1, hasPrevious: talkIndex > 0,
                    sleepTimerLabel: mode == .playing ? "24 min" : nil
                )
            },
            accentName: accentName,
            savedPositions: store.inventory.compactMap { phoneSaves[$0] }
        )
    }

    private func recordPhoneMove() {
        guard let talk = currentTalk else { return }
        phoneSaves[talk.id] = CompanionSavedPosition(discourseID: talk.id, position: position, finished: false, savedAt: Date())
    }

    private func move(by offset: Int) {
        talkIndex = max(0, min(WatchDebugFixtures.talks.count - 1, talkIndex + offset))
        position = 0
        recordPhoneMove()
    }

    private func makePage(_ location: CompanionLocation, inventory: Set<String>) -> CompanionPage {
        let talks = mode == .empty ? [] : WatchDebugFixtures.talks
        func row(_ talk: WatchDebugFixtures.Talk) -> CompanionRow {
            let progress = talk.duration > 0 && talk.position > 0 ? min(1, talk.position / talk.duration) : nil
            let left = Int((talk.duration - talk.position) / 60)
            return CompanionRow(
                id: "d:" + talk.id, kind: .discourse, title: talk.title,
                subtitle: progress == nil || left <= 0 ? talk.series : "\(talk.series) · \(left) min left",
                progress: progress, isCurrent: talk.id == currentTalk?.id, isOnWatch: inventory.contains(talk.id)
            )
        }
        switch location {
        case .continueListening:
            return CompanionPage(location: location, title: "Continue Listening",
                                 rows: talks.filter { $0.position > 0 }.map(row), isTruncated: false,
                                 emptyMessage: "Talks you start on iPhone appear here.")
        case .downloads:
            return CompanionPage(location: location, title: "Downloads", rows: talks.map {
                CompanionRow(id: "s:" + $0.series, kind: .series, title: $0.series, subtitle: "1 discourse")
            }, isTruncated: false, emptyMessage: "Download discourses on your iPhone to play them here.")
        case .series(let rowID):
            return CompanionPage(location: location, title: String(rowID.dropFirst(2)),
                                 rows: talks.filter { "s:" + $0.series == rowID }.map(row), isTruncated: false,
                                 emptyMessage: "No downloaded discourses in this series.")
        case .bookmarks:
            return CompanionPage(location: location, title: "Bookmarks", rows: talks.prefix(2).map {
                CompanionRow(id: "b:\($0.id)@1", kind: .bookmark, title: "Awareness is the key",
                             subtitle: "18:04 · \($0.title)")
            }, isTruncated: false, emptyMessage: "Bookmarks for downloaded discourses appear here.")
        }
    }

    private func deliverLater(_ discourseID: String) {
        guard let talk = WatchDebugFixtures.talks.first(where: { $0.id == discourseID }) else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self else { return }
            let saved = phoneSaves[discourseID]
            WatchDebugFixtures.seed(talk, into: store, scratch: scratch,
                                    position: saved.map { $0.finished ? 0 : $0.position } ?? 0, savedAt: saved?.savedAt)
            if let entry = store.entry(for: discourseID) { onEvent?(.offlineFileStored(entry)) }
        }
    }

    private func advance() {
        let now = WatchClock.now
        if isPlaying, let talk = currentTalk {
            position = min(talk.duration, position + max(0, now - lastClock) * Double(rate))
            recordPhoneMove()
        }
        lastClock = now
    }
}
#endif
