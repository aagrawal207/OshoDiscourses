import Foundation
import os
import StoreKit

/// Anonymous usage signals for TelemetryDeck. Nothing identifies a listener: no
/// names, no Apple ID, no bookmark notes, search text or transcript text. The
/// SDK hashes its install ID before sending.
///
/// Callers report events as they happen. Events are counted on the device and
/// sent as one `Usage.summary` plus one `Listening.talk` per talk heard, at most
/// every `summaryInterval`, so a listener costs a few signals a day.
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
    private var pending: PendingUsage?
    private var carPlayActive = false
    private var downloadOrigins: [String: DownloadOrigin] = [:]
    private var pendingRate: (value: Double, task: Task<Void, Never>)?
    private var pendingLibrarySearch: Task<Void, Never>?
    private let log = Logger(subsystem: "com.agraabhi.oshodiscourses", category: "Telemetry")

    /// Library sizes added to each summary; set by `AppRuntime`.
    var librarySizes: (() -> [String: String])?

    /// A segment longer than this is counted while playback continues, so audio
    /// that keeps the app running for hours is not lost if iOS ends the process.
    static let listeningFlushSeconds: Double = 30 * 60
    /// The shortest gap between summaries. Twelve hours keeps it near one a day
    /// while a first-day listener is still counted when they leave the app.
    static let summaryInterval: TimeInterval = 12 * 60 * 60
    /// Talks heard for less than this are only counted in the summary totals.
    static let talkMinimumSeconds: Double = 60
    static let maximumTalksPerSummary = 10
    /// Events sent at once because they are rare and their detail matters.
    static let immediateSignals: Set<TelemetrySignal> = [.supportPurchase]

    private let rateDebounce: Duration
    private let searchDebounce: Duration

    private enum Keys {
        static let pending = "telemetry.pending.v1"
        static let lastSummary = "telemetry.lastSummary"
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
        sendSummaryIfDue(trigger: .launch)
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isRunning else { return }
        if enabled, Self.isUnitTestHost, !sink.isTestSink { return }
        if enabled {
            let context = context
            sink.start(appID: Self.appID, namespace: Self.namespace) { context.parameters }
            pending = loadPending()
            isRunning = true
        } else {
            listening = nil
            pending = nil
            defaults.removeObject(forKey: Keys.pending)
            downloadOrigins.removeAll()
            pendingRate?.task.cancel()
            pendingRate = nil
            pendingLibrarySearch?.cancel()
            pendingLibrarySearch = nil
            sink.stop()
            isRunning = false
        }
    }

    // MARK: - Context

    private var settingsContext: [String: String] = [:]
    private var extraContext: [String: String] = [:]

    /// Settings added to every signal, so feature adoption is a filter on any chart.
    func updateContext(_ parameters: [String: String]) {
        settingsContext = parameters
        context.parameters = settingsContext.merging(extraContext) { $1 }
    }

    /// A non-setting value added to every signal, such as the Watch link state.
    func setContextValue(_ value: String?, for key: String) {
        extraContext[key] = value
        context.parameters = settingsContext.merging(extraContext) { $1 }
    }

    // MARK: - Events

    /// Records an event. Most are counted for the next summary; `immediateSignals` go now.
    func send(_ signal: TelemetrySignal, _ parameters: [String: String] = [:], value: Double? = nil) {
        guard isRunning else { return }
        log.debug("\(signal.rawValue, privacy: .public) \(parameters.description, privacy: .public)")
        sink.noteEvent(signal.rawValue, parameters: parameters, floatValue: value)
        if Self.immediateSignals.contains(signal) {
            sink.send(signal.rawValue, parameters: parameters, floatValue: value)
            return
        }
        count(signal, parameters, value: value)
        savePending()
    }

    /// A verified tip or yearly-support transaction, through TelemetryDeck's
    /// purchase preset so its revenue charts work.
    func purchaseCompleted(_ transaction: Transaction, parameters: [String: String] = [:]) {
        guard isRunning else { return }
        sink.purchaseCompleted(transaction, parameters: parameters)
    }

    private func count(_ signal: TelemetrySignal, _ parameters: [String: String], value: Double?) {
        var usage = pending ?? PendingUsage(since: now())
        usage.add(signal.rawValue)
        for key in signal.countedDimensions {
            if let dimension = parameters[key] { usage.add("\(signal.rawValue).\(key).\(dimension)") }
        }
        if let value, signal.valueIsSeconds { usage.addSeconds(value, to: signal.rawValue) }
        pending = usage
    }

    // MARK: - Listening

    /// A new talk began playing. Any open segment for the previous talk is counted first.
    func playbackStarted(_ discourseID: String, kind: PlaybackKind, reason: PlaybackStartReason, rate: Double) {
        flushListening(trigger: .switched)
        guard isRunning else { return }
        listening = ListeningSegment(discourseID: discourseID, kind: kind, reason: reason, rate: rate)
    }

    /// Playback resumed. Opens a segment when the last one was already counted, for
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
        if carPlayActive {
            var usage = pending ?? PendingUsage(since: now())
            usage.addSeconds(seconds, to: "CarPlay.listening")
            pending = usage
        }
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

    /// Counts the open segment. With `continuing`, a new segment for the same talk
    /// starts so the rest of the listen is counted on the next flush.
    func flushListening(trigger: ListeningEndTrigger, continuing: Bool = false) {
        guard let segment = listening else { return }
        listening = nil
        if segment.seconds >= 1 || segment.completed {
            record(segment, trigger: trigger)
        }
        if continuing, isRunning {
            listening = ListeningSegment(
                discourseID: segment.discourseID, kind: segment.kind, reason: .continued, rate: segment.rate
            )
        }
    }

    private func record(_ segment: ListeningSegment, trigger: ListeningEndTrigger) {
        guard isRunning else { return }
        var parameters = TelemetryParameters.discourse(segment.discourseID)
        parameters.merge(segment.kind.parameters) { $1 }
        parameters["startReason"] = segment.reason.rawValue
        parameters["endTrigger"] = trigger.rawValue
        parameters["completed"] = TelemetryParameters.flag(segment.completed)
        parameters["skipsForward"] = TelemetryParameters.bucket(segment.skipsForward)
        parameters["skipsBack"] = TelemetryParameters.bucket(segment.skipsBack)
        parameters["seeks"] = TelemetryParameters.bucket(segment.seeks)
        parameters["rate"] = TelemetryParameters.rate(segment.rate)
        parameters["minutes"] = TelemetryParameters.minutesBucket(segment.seconds)
        sink.noteEvent(TelemetrySignal.listeningSession.rawValue, parameters: parameters, floatValue: segment.seconds.rounded())

        var usage = pending ?? PendingUsage(since: now())
        let isNewListen = segment.reason != .continued && segment.reason != .recovered
        usage.addSeconds(segment.seconds, to: "Listening")
        usage.addSeconds(segment.seconds, to: "Listening.\(segment.kind.name)")
        if isNewListen { usage.add("Listening.starts.\(segment.reason.rawValue)") }
        if segment.completed { usage.add("Listening.completed") }
        usage.add("Listening.skipsForward", by: segment.skipsForward)
        usage.add("Listening.skipsBack", by: segment.skipsBack)
        usage.add("Listening.seeks", by: segment.seeks)
        usage.addTalk(segment, isNewListen: isNewListen)
        pending = usage
        savePending()
    }

    // MARK: - Summary

    /// Sends the counted usage when some exists and the last summary is old enough.
    func sendSummaryIfDue(trigger: SummaryTrigger) {
        guard isRunning, let usage = pending, !usage.isEmpty else { return }
        if let last = defaults.object(forKey: Keys.lastSummary) as? Date,
           now().timeIntervalSince(last) < Self.summaryInterval { return }

        var parameters = usage.counters.mapValues(TelemetryParameters.count)
        for (name, seconds) in usage.seconds {
            parameters["\(name).minutes"] = String(Int((seconds / 60).rounded()))
        }
        parameters.merge(librarySizes?() ?? [:]) { $1 }
        parameters["trigger"] = trigger.rawValue
        parameters["periodHours"] = TelemetryParameters.bucket(Int(now().timeIntervalSince(usage.since) / 3600))
        let listeningMinutes = ((usage.seconds["Listening"] ?? 0) / 60).rounded()
        sink.send(TelemetrySignal.usageSummary.rawValue, parameters: parameters, floatValue: listeningMinutes)

        let talks = usage.talks.values
            .filter { $0.seconds >= Self.talkMinimumSeconds || $0.completed }
            .sorted { $0.seconds > $1.seconds }
        for talk in talks.prefix(Self.maximumTalksPerSummary) {
            sink.send(TelemetrySignal.listeningTalk.rawValue, parameters: talk.parameters, floatValue: talk.seconds.rounded())
        }

        defaults.set(now(), forKey: Keys.lastSummary)
        pending = nil
        defaults.removeObject(forKey: Keys.pending)
    }

    /// Saves the counted usage; the app calls this when it leaves the screen.
    func savePending() {
        guard isRunning else { return }
        guard let pending, let data = try? JSONEncoder().encode(pending) else {
            defaults.removeObject(forKey: Keys.pending)
            return
        }
        defaults.set(data, forKey: Keys.pending)
    }

    private func loadPending() -> PendingUsage? {
        guard let data = defaults.data(forKey: Keys.pending) else { return nil }
        return try? JSONDecoder().decode(PendingUsage.self, from: data)
    }

    #if DEBUG
    var pendingCounters: [String: Int] { pending?.counters ?? [:] }
    var pendingSeconds: [String: Double] { pending?.seconds ?? [:] }
    #endif

    // MARK: - CarPlay

    func setCarPlayActive(_ active: Bool) {
        carPlayActive = active
    }

    // MARK: - Debounced events

    /// The speed slider moves in 0.05 steps; only the value it settles on is counted.
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

    /// Library search filters as the listener types; one event is counted after
    /// typing stops. The query itself is never recorded, only its length and results.
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
}

enum SummaryTrigger: String, Sendable {
    case launch
    case foreground
    case background
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

/// Usage counted since the last summary, saved so it survives relaunches.
private struct PendingUsage: Codable {
    var since: Date
    var counters: [String: Int] = [:]
    var seconds: [String: Double] = [:]
    var talks: [String: TalkTally] = [:]

    var isEmpty: Bool { counters.isEmpty && seconds.isEmpty && talks.isEmpty }

    mutating func add(_ key: String, by amount: Int = 1) {
        guard amount > 0 else { return }
        counters[key, default: 0] += amount
    }

    mutating func addSeconds(_ value: Double, to key: String) {
        guard value > 0 else { return }
        seconds[key, default: 0] += value
    }

    mutating func addTalk(_ segment: ListeningSegment, isNewListen: Bool) {
        let key = "\(segment.discourseID)|\(segment.kind.name)|\(segment.kind.targetLanguage ?? "")"
        var talk = talks[key] ?? TalkTally(
            discourseID: segment.discourseID, kind: segment.kind.name,
            sourceLanguage: segment.kind.sourceLanguage, targetLanguage: segment.kind.targetLanguage
        )
        talk.seconds += segment.seconds
        talk.completed = talk.completed || segment.completed
        if isNewListen { talk.starts += 1 }
        talks[key] = talk
    }
}

private struct TalkTally: Codable {
    let discourseID: String
    let kind: String
    let sourceLanguage: String?
    let targetLanguage: String?
    var seconds: Double = 0
    var completed = false
    var starts = 0

    var parameters: [String: String] {
        var parameters = TelemetryParameters.discourse(discourseID)
        parameters["kind"] = kind
        parameters["sourceLanguage"] = sourceLanguage
        parameters["targetLanguage"] = targetLanguage
        parameters["completed"] = TelemetryParameters.flag(completed)
        parameters["starts"] = TelemetryParameters.count(starts)
        parameters["minutes"] = TelemetryParameters.minutesBucket(seconds)
        return parameters
    }
}
