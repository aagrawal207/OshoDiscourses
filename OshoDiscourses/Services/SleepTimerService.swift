import Foundation
import Observation

@Observable
@MainActor
final class SleepTimerService {

    static let shared = SleepTimerService()

    var remainingTime: TimeInterval = 0
    var onExpire: (() -> Void)?

    var isActive: Bool { remainingTime > 0 }

    var formattedRemaining: String {
        let total = Int(remainingTime)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var timerTask: Task<Void, Never>?

    private init() {}

    func start(minutes: Int) {
        cancel()
        remainingTime = TimeInterval(minutes * 60)
        timerTask = Task { [weak self] in
            while let self, self.remainingTime > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self.remainingTime = max(self.remainingTime - 1, 0)
            }
            guard let self, !Task.isCancelled else { return }
            self.onExpire?()
            self.remainingTime = 0
        }
    }

    func cancel() {
        timerTask?.cancel()
        timerTask = nil
        remainingTime = 0
    }
}
