import Foundation
import Observation

@Observable
@MainActor
final class SleepTimerService {

    static let shared = SleepTimerService()

    enum Mode: Equatable {
        /// No timer armed.
        case off
        /// Counting down a fixed number of minutes.
        case countdown
        /// Stop when the current discourse plays to its natural end. There is no
        /// countdown — the player calls `discourseDidFinish()` on completion, so
        /// this stays correct even if the listener seeks around.
        case endOfDiscourse
    }

    private(set) var mode: Mode = .off
    var remainingTime: TimeInterval = 0
    var onExpire: (() -> Void)?

    var isActive: Bool { mode != .off }

    /// Short label for the player's Sleep button.
    var statusLabel: String {
        switch mode {
        case .off: return "Sleep"
        case .countdown: return formattedRemaining
        case .endOfDiscourse: return "End"
        }
    }

    var formattedRemaining: String {
        let total = Int(remainingTime)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var timerTask: Task<Void, Never>?
    /// The choice that armed the timer, sent with a cancellation.
    @ObservationIgnored private var telemetryOption: String?

    private init() {}

    func start(minutes: Int) {
        cancel()
        mode = .countdown
        telemetryOption = String(minutes)
        TelemetryService.shared.send(.sleepTimerStarted, ["option": String(minutes)])
        let duration = TimeInterval(minutes * 60)
        remainingTime = duration
        // Count against an absolute deadline rather than decrementing per tick:
        // Task.sleep guarantees *at least* the interval, so 1-per-tick drifts
        // over a long timer, and a suspended app would silently pause the
        // countdown entirely. Deriving remaining from the deadline stays
        // correct across drift and suspension alike.
        let deadline = Date().addingTimeInterval(duration)
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                let remaining = deadline.timeIntervalSinceNow
                guard let self else { return }
                if remaining <= 0 {
                    self.fire()
                    return
                }
                self.remainingTime = remaining
                // Wake at least once a second for the label; sooner when the
                // deadline is closer so expiry doesn't overshoot.
                try? await Task.sleep(for: .seconds(min(1, remaining)))
            }
        }
    }

    /// Arm the timer to stop playback when the current discourse finishes.
    func startUntilEndOfDiscourse() {
        cancel()
        mode = .endOfDiscourse
        telemetryOption = Self.endOfDiscourseOption
        TelemetryService.shared.send(.sleepTimerStarted, ["option": Self.endOfDiscourseOption])
    }

    private static let endOfDiscourseOption = "endOfDiscourse"

    /// Called by the player when a track plays through to the end. Fires the
    /// expire action if (and only if) end-of-discourse mode is armed.
    func discourseDidFinish() {
        guard mode == .endOfDiscourse else { return }
        fire()
    }

    /// The listener turned the timer off. `cancel()` also runs on expiry and restarts, which are not signals.
    func cancelByListener() {
        guard isActive else { return }
        TelemetryService.shared.send(.sleepTimerCancelled, ["option": telemetryOption ?? "unknown"])
        cancel()
    }

    func cancel() {
        timerTask?.cancel()
        timerTask = nil
        remainingTime = 0
        mode = .off
        telemetryOption = nil
    }

    /// Run the expire action and reset to off. Snapshots the callback before
    /// reset so cancellation can't race it away.
    private func fire() {
        let callback = onExpire
        cancel()
        callback?()
    }
}
