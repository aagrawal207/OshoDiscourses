import Foundation
import os
import StoreKit

/// Anonymous usage signals for TelemetryDeck. Nothing identifies a listener: no
/// names, no Apple ID, no bookmark notes, search text or transcript text. The
/// SDK hashes its install ID before sending. Catalog IDs (series, discourse) are
/// sent so the most played talks can be ranked.
@MainActor
final class TelemetryService {
    static let shared = TelemetryService()

    static let appID = "584A18B7-DDF4-4BF5-9A28-C687DCEB6489"
    static let namespace = "com.abhishekagrawal"

    private var sink: TelemetrySink
    private let defaults: UserDefaults
    private let now: () -> Date
    private let context = TelemetryContext()
    private(set) var isRunning = false
    private var listening: ListeningSegment?
    private var downloadOrigins: [String: DownloadOrigin] = [:]
    private var pendingRate: (value: Double, task: Task<Void, Never>)?
    private var pendingLibrarySearch: Task<Void, Never>?
    private let log = Logger(subsystem: "com.agraabhi.oshodiscourses", category: "Telemetry")

    /// A segment longer than this is sent while playback continues, so audio that
    /// keeps the app running for hours is not lost if iOS ends the process.
    static let listeningFlushSeconds: Double = 30 * 60
    /// The library snapshot (counts of downloads, bookmarks and so on) goes at most weekly.
    static let snapshotInterval: TimeInterval = 7 * 24 * 60 * 60
    private let rateDebounce: Duration
    private let searchDebounce: Duration

    private enum Keys {
        static let lastSnapshot = "telemetry.lastSnapshot"
    }

    init(
        sink: TelemetrySink = TelemetryDeckSink(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        rateDebounce: Duration = .seconds(2),
        searchDebounce: Duration = .milliseconds(1500)
    ) {
        self.sink = sink
        self.defaults = defaults
        self.now = now
        self.rateDebounce = rateDebounce
        self.searchDebounce = searchDebounce
    }

    #if DEBUG
    /// Lets unit tests observe the shared service, which other services call directly.
    func installTestSink(_ testSink: TelemetrySink) {
        setEnabled(false)
        sink = testSink
        setEnabled(true)
    }

    func removeTestSink() {
        setEnabled(false)
        sink = TelemetryDeckSink()
    }
    #endif

    /// Unit tests share the app host, so the shared service never sends from a test run.
    private static var isUnitTestHost: Bool { NSClassFromString("XCTestCase") != nil }

    /// Called from `AppRuntime.start()`, so a CarPlay-only launch is counted too.
    func start(enabled: Bool) {
        setEnabled(enabled)
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isRunning else { return }
        if enabled, Self.isUnitTestHost, !sink.isTestSink { return }
        if enabled {
            let context = context
            sink.start(appID: Self.appID, namespace: Self.namespace) { context.parameters }
            isRunning = true
        } else {
            listening = nil
            downloadOrigins.removeAll()
            pendingRate?.task.cancel()
            pendingRate = nil
            pendingLibrarySearch?.cancel()
            pendingLibrarySearch = nil
            sink.stop()
            isRunning = false
        }
    }

    /// Parameters added to every signal, including the SDK's own session signals,
    /// so feature adoption is a filter on any chart.
    func updateContext(_ parameters: [String: String]) {
        context.parameters = parameters
    }

    func send(_ signal: TelemetrySignal, _ parameters: [String: String] = [:], value: Double? = nil) {
        guard isRunning else { return }
        log.debug("\(signal.rawValue, privacy: .public) \(parameters.description, privacy: .public)")
        sink.send(signal.rawValue, parameters: parameters, floatValue: value)
    }

    /// A verified tip or yearly-support transaction, through TelemetryDeck's
    /// purchase preset so its revenue charts work.
    func purchaseCompleted(_ transaction: Transaction, parameters: [String: String] = [:]) {
        guard isRunning else { return }
        sink.purchaseCompleted(transaction, parameters: parameters)
    }

    // MARK: - Listening

    /// A new talk began playing. Any open segment for the previous talk is sent first.
    func playbackStarted(_ discourseID: String, kind: PlaybackKind, reason: PlaybackStartReason, rate: Double) {
        flushListening(trigger: .switched)
        guard isRunning else { return }
        listening = ListeningSegment(discourseID: discourseID, kind: kind, reason: reason, rate: rate)
    }

    /// Playback resumed. Opens a segment when the last one was already sent, for
    /// example a talk paused before the app went to the background.
    func playbackResumed(
        _ discourseID: String, kind: PlaybackKind, rate: Double, reason: PlaybackStartReason = .continued
    ) {
        guard isRunning, listening == nil else { return }
        listening = ListeningSegment(discourseID: discourseID, kind: kind, reason: reason, rate: rate)
    }

    func addListening(seconds: Double) {
        guard seconds > 0, listening != nil else { return }
        listening?.seconds += seconds
        if let seconds = listening?.seconds, seconds >= Self.listeningFlushSeconds {
            flushListening(trigger: .periodic, continuing: true)
        }
    }

    func noteListening(_ action: ListeningAction) {
        switch action {
        case .skipForward: listening?.skipsForward += 1
        case .skipBack: listening?.skipsBack += 1
        case .seek: listening?.seeks += 1
        }
    }

    /// The current talk reached its end (or the listener skipped to its end).
    func playbackFinished(naturally: Bool) {
        listening?.completed = naturally
        flushListening(trigger: naturally ? .finished : .skippedToEnd)
    }

    /// Sends the open segment. With `continuing`, a new segment for the same talk
    /// starts so the rest of the listen is counted on the next flush.
    func flushListening(trigger: ListeningEndTrigger, continuing: Bool = false) {
        guard let segment = listening else { return }
        listening = nil
        if segment.seconds >= 1 || segment.completed {
            var parameters = TelemetryParameters.discourse(segment.discourseID)
            parameters.merge(segment.kind.parameters) { $1 }
            parameters["startReason"] = segment.reason.rawValue
            parameters["endTrigger"] = trigger.rawValue
            parameters["completed"] = segment.completed ? "true" : "false"
            parameters["skipsForward"] = TelemetryParameters.bucket(segment.skipsForward)
            parameters["skipsBack"] = TelemetryParameters.bucket(segment.skipsBack)
            parameters["seeks"] = TelemetryParameters.bucket(segment.seeks)
            parameters["rate"] = TelemetryParameters.rate(segment.rate)
            parameters["minutes"] = TelemetryParameters.minutesBucket(segment.seconds)
            send(.listeningSession, parameters, value: segment.seconds.rounded())
        }
        if continuing, isRunning {
            listening = ListeningSegment(
                discourseID: segment.discourseID, kind: segment.kind, reason: .continued, rate: segment.rate
            )
        }
    }

    // MARK: - Debounced settings

    /// The speed slider moves in 0.05 steps; only the value it settles on is sent.
    func playbackRateChanged(_ rate: Double) {
        guard isRunning else { return }
        listening?.rate = rate
        pendingRate?.task.cancel()
        let delay = rateDebounce
        let task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.send(.speedChanged, ["rate": TelemetryParameters.rate(rate)])
            self?.pendingRate = nil
        }
        pendingRate = (rate, task)
    }

    /// Library search filters as the listener types; one signal goes after typing
    /// stops. The query itself is never sent, only its length and result count.
    func librarySearchChanged(queryLength: Int, resultCount: Int) {
        guard isRunning else { return }
        pendingLibrarySearch?.cancel()
        guard queryLength > 0 else { pendingLibrarySearch = nil; return }
        let delay = searchDebounce
        pendingLibrarySearch = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.send(.librarySearched, [
                "queryLength": TelemetryParameters.bucket(queryLength),
                "results": TelemetryParameters.bucket(resultCount),
            ])
            self?.pendingLibrarySearch = nil
        }
    }

    // MARK: - Downloads

    /// Callers tag who asked before `DownloadService.download`, which cannot tell.
    func noteDownloadOrigin(_ discourseID: String, _ origin: DownloadOrigin) {
        guard isRunning else { return }
        downloadOrigins[discourseID] = origin
    }

    /// The origin recorded for a download, consumed by its completion or failure.
    /// A transfer that finished after a relaunch has no recorded origin.
    func takeDownloadOrigin(_ discourseID: String) -> DownloadOrigin {
        downloadOrigins.removeValue(forKey: discourseID) ?? .unknown
    }

    // MARK: - Weekly snapshot

    /// Sends library counts at most once a week. `make` runs only when one is due.
    func sendSnapshotIfDue(_ make: () -> [String: String]) {
        guard isRunning else { return }
        let last = defaults.object(forKey: Keys.lastSnapshot) as? Date
        if let last, now().timeIntervalSince(last) < Self.snapshotInterval { return }
        defaults.set(now(), forKey: Keys.lastSnapshot)
        send(.librarySnapshot, make())
    }
}

/// Holds the shared parameters for the SDK's `defaultParameters` closure, which
/// runs off the main actor.
final class TelemetryContext: Sendable {
    private let storage = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    var parameters: [String: String] {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}

private struct ListeningSegment {
    let discourseID: String
    let kind: PlaybackKind
    let reason: PlaybackStartReason
    var rate: Double
    var seconds: Double = 0
    var skipsForward = 0
    var skipsBack = 0
    var seeks = 0
    var completed = false
}
