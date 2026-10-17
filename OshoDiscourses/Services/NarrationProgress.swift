import Foundation

/// Weights progress by source characters, since one passage can be ten times longer than the next.
struct NarrationProgressEstimator: Equatable, Sendable {
    private let lengths: [Int]
    private let total: Int
    private let startedAt: TimeInterval
    private let baseline: Int
    private(set) var completed: Set<Int>
    private(set) var completedCharacters: Int
    private var translated: Set<Int> = []
    private var translatedCharacters = 0
    private var completedThisRun = 0
    private var lastCompletionAt: TimeInterval?

    // A first passage also pays for language setup and the first translation batch.
    static let minimumPassages = 2
    static let minimumElapsed: TimeInterval = 10

    init(lengths: [Int], completed: Set<Int>, startedAt: TimeInterval) {
        let lengths = lengths.map { max(1, $0) }
        let completed = completed.filter { lengths.indices.contains($0) }
        let done = completed.reduce(0) { $0 + lengths[$1] }
        self.lengths = lengths
        total = lengths.reduce(0, +)
        self.completed = completed
        completedCharacters = done
        baseline = done
        self.startedAt = startedAt
    }

    var passageCount: Int { lengths.count }
    var completedPassages: Int { completed.count }

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(completedCharacters) / Double(total))
    }

    /// Work done including passages translated but not yet spoken, which count as half done.
    /// Translation is the slow step, so iOS sees progress during it instead of a long stall.
    var workFraction: Double {
        guard total > 0 else { return 0 }
        return min(1, (Double(completedCharacters) + Double(translatedCharacters) / 2) / Double(total))
    }

    mutating func markTranslated(_ indices: some Sequence<Int>) {
        for index in indices where lengths.indices.contains(index) && !completed.contains(index) {
            if translated.insert(index).inserted { translatedCharacters += lengths[index] }
        }
    }

    mutating func complete(_ index: Int, at now: TimeInterval) {
        guard lengths.indices.contains(index), completed.insert(index).inserted else { return }
        if translated.remove(index) != nil { translatedCharacters -= lengths[index] }
        completedCharacters += lengths[index]
        completedThisRun += 1
        lastCompletionAt = now
    }

    /// Nil until this run has enough evidence; earlier saved passages say nothing about this run's speed.
    var secondsRemaining: TimeInterval? {
        guard let lastCompletionAt, completedThisRun >= Self.minimumPassages else { return nil }
        let elapsed = lastCompletionAt - startedAt
        let done = completedCharacters - baseline
        guard elapsed >= Self.minimumElapsed, done > 0 else { return nil }
        let remaining = total - completedCharacters
        guard remaining > 0 else { return 0 }
        return Double(remaining) * elapsed / Double(done)
    }
}

enum NarrationTimeFormatting {
    static func remaining(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "Estimating time…" }
        guard seconds >= 60 else { return "Less than a minute left" }
        let minutes = Int((seconds / 60).rounded(.up))
        guard minutes >= 60 else { return "About \(minutes) min left" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "About \(hours) hr left" : "About \(hours) hr \(rest) min left"
    }

    static func passages(_ completed: Int, of total: Int) -> String {
        "\(completed) of \(total) passages"
    }
}

enum NarrationBackgroundReason: String, Equatable, Sendable {
    case notSupported, registrationRejected, schedulerUnavailable, tooManyRequests, notPermitted
    case immediateRunIneligible, submissionFailed, attachmentRejected, expired, notGranted, cancelled, preparationFailed

    var message: String {
        switch self {
        case .notSupported: "Background preparation isn't available on this device."
        case .registrationRejected: "iOS couldn't register background preparation."
        case .schedulerUnavailable: "Background processing is unavailable in the current system settings."
        case .tooManyRequests: "iOS has too many background tasks pending."
        case .notPermitted: "iOS didn't permit this background task."
        case .immediateRunIneligible: "iOS couldn't grant background time under current system conditions."
        case .submissionFailed: "The background request couldn't be submitted."
        case .attachmentRejected: "iOS didn't provide a usable background task."
        case .expired: "iOS ended background time or the task was stopped in system controls."
        case .notGranted: "Background time hadn't been granted when the app left the screen."
        case .cancelled: "Preparation was paused."
        case .preparationFailed: "Preparation stopped before it could finish."
        }
    }
}

enum NarrationBackgroundStatus: Equatable, Sendable {
    case idle
    case unavailable(NarrationBackgroundReason)
    case requesting
    case running
    case paused(NarrationBackgroundReason)

    var message: String {
        switch self {
        case .idle: ""
        case .requesting: "Requesting background time. Keep the app open until it's granted."
        case .running: "Background time granted. iOS can still pause preparation."
        case .unavailable(let reason): reason.message + " Keep the app open to prepare audio."
        case .paused(let reason): reason.message + " Finished passages are saved."
        }
    }

    var logValue: String {
        switch self {
        case .idle: "idle"
        case .requesting: "requesting"
        case .running: "running"
        case .unavailable(let reason): "unavailable.\(reason.rawValue)"
        case .paused(let reason): "paused.\(reason.rawValue)"
        }
    }
}

/// A submission is not a grant: asynchronous implementations report running only after attachment.
@MainActor
protocol NarrationBackgroundActivity: AnyObject {
    /// Legacy synchronous implementations return true only when background time is already granted.
    func begin(title: String, subtitle: String, onExpire: @escaping @MainActor () -> Void) -> Bool
    func begin(
        title: String, subtitle: String,
        onStatusChange: @escaping @MainActor (NarrationBackgroundStatus) -> Void,
        onExpire: @escaping @MainActor () -> Void
    )
    func update(fraction: Double, subtitle: String)
    func end(success: Bool)
}

extension NarrationBackgroundActivity {
    func begin(
        title: String, subtitle: String,
        onStatusChange: @escaping @MainActor (NarrationBackgroundStatus) -> Void,
        onExpire: @escaping @MainActor () -> Void
    ) {
        let granted = begin(title: title, subtitle: subtitle, onExpire: onExpire)
        onStatusChange(granted ? .running : .unavailable(.submissionFailed))
    }
}
