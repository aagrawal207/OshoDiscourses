import Foundation

/// Weights progress by source characters, since one passage can be ten times longer than the next.
struct NarrationProgressEstimator: Equatable, Sendable {
    private let lengths: [Int]
    private let total: Int
    private let startedAt: TimeInterval
    private let baseline: Int
    private(set) var completed: Set<Int>
    private(set) var completedCharacters: Int
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

    mutating func complete(_ index: Int, at now: TimeInterval) {
        guard lengths.indices.contains(index), completed.insert(index).inserted else { return }
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

/// Keeps a user-started preparation running after the app leaves the screen, with system progress UI.
@MainActor
protocol NarrationBackgroundActivity: AnyObject {
    /// False when the system will not keep the work alive; callers then pause when the app leaves the screen.
    func begin(title: String, subtitle: String, onExpire: @escaping @MainActor () -> Void) -> Bool
    func update(fraction: Double, subtitle: String)
    func end(success: Bool)
}
