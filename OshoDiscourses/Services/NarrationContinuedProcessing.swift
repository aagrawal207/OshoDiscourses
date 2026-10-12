#if os(iOS) && !targetEnvironment(macCatalyst)
import BackgroundTasks
import Foundation
import os

/// Each preparation gets its own identifier: the scheduler allows one registration per identifier.
@available(iOS 26.0, *)
@MainActor
final class NarrationContinuedProcessing: NarrationBackgroundActivity {
    private static let log = Logger(subsystem: "com.agraabhi.oshodiscourses", category: "NarrationBackground")
    private static let units: Int64 = 1_000

    private let scheduler: BGTaskScheduler
    private var identifier: String?
    private var task: BGContinuedProcessingTask?
    private var title = ""
    private var latest: (fraction: Double, subtitle: String) = (0, "")
    private var onExpire: (@MainActor () -> Void)?

    init(scheduler: BGTaskScheduler = .shared) {
        self.scheduler = scheduler
    }

    func begin(title: String, subtitle: String, onExpire: @escaping @MainActor () -> Void) -> Bool {
        end(success: false)
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let identifier = "\(bundleID).narration.\(UUID().uuidString)"
        let registered = scheduler.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated { self?.attach(task, identifier: identifier) }
        }
        guard registered else {
            Self.log.error("stage=register outcome=rejected")
            return false
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        // Queued work could start after the listener has left; this job only makes sense right now.
        request.strategy = .fail
        do {
            try scheduler.submit(request)
        } catch {
            let code = (error as NSError).code
            Self.log.notice("stage=submit outcome=failed code=\(code, privacy: .public)")
            return false
        }
        self.identifier = identifier
        self.title = title
        latest = (0, subtitle)
        self.onExpire = onExpire
        Self.log.info("stage=submit outcome=submitted")
        return true
    }

    func update(fraction: Double, subtitle: String) {
        guard identifier != nil else { return }
        latest = (fraction.isFinite ? min(1, max(0, fraction)) : 0, subtitle)
        apply()
    }

    func end(success: Bool) {
        guard let identifier else { return }
        if let task {
            if success { task.progress.completedUnitCount = Self.units }
            task.setTaskCompleted(success: success)
        } else {
            scheduler.cancel(taskRequestWithIdentifier: identifier)
        }
        Self.log.info("stage=end outcome=\(success ? "completed" : "stopped", privacy: .public) attached=\(self.task != nil, privacy: .public)")
        self.identifier = nil
        task = nil
        onExpire = nil
    }

    private func attach(_ launched: BGTask, identifier: String) {
        guard identifier == self.identifier, let launched = launched as? BGContinuedProcessingTask else {
            launched.setTaskCompleted(success: false)
            Self.log.notice("stage=launch outcome=stale")
            return
        }
        task = launched
        launched.progress.totalUnitCount = Self.units
        launched.expirationHandler = { [weak self] in
            Task { @MainActor in self?.expire(identifier) }
        }
        apply()
        Self.log.info("stage=launch outcome=running")
    }

    private func expire(_ identifier: String) {
        guard identifier == self.identifier else { return }
        Self.log.notice("stage=expire outcome=expired")
        let handler = onExpire
        end(success: false)
        handler?()
    }

    private func apply() {
        guard let task else { return }
        task.progress.completedUnitCount = Int64((latest.fraction * Double(Self.units)).rounded(.down))
        task.updateTitle(title, subtitle: latest.subtitle)
    }
}
#endif
