import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif

/// The short time iOS gives after the app leaves the screen, about 30 seconds, with no lock-screen banner.
/// Longer runs need audio playing; the app continues the rest when it is opened again.
@MainActor
final class NarrationGraceTime: NarrationBackgroundActivity {
    typealias Begin = @MainActor (_ expire: @escaping @MainActor () -> Void) -> Int?
    typealias End = @MainActor (Int) -> Void

    private static let log = Logger(subsystem: "com.agraabhi.oshodiscourses", category: "NarrationBackground")
    private let beginTask: Begin
    private let endTask: End
    private var task: Int?
    private var onExpire: (@MainActor () -> Void)?
    private var generation = 0

    init(begin: @escaping Begin, end: @escaping End) {
        beginTask = begin
        endTask = end
    }

    func begin(title: String, subtitle: String, onExpire: @escaping @MainActor () -> Void) -> Bool {
        begin(title: title, subtitle: subtitle, onStatusChange: { _ in }, onExpire: onExpire)
        return task != nil
    }

    func begin(
        title: String, subtitle: String,
        onStatusChange: @escaping @MainActor (NarrationBackgroundStatus) -> Void,
        onExpire: @escaping @MainActor () -> Void
    ) {
        end(success: false)
        generation &+= 1
        let current = generation
        guard let task = beginTask({ [weak self] in self?.expire(current) }) else {
            Self.log.notice("stage=grace outcome=refused")
            onStatusChange(.unavailable(.notPermitted))
            return
        }
        self.task = task
        self.onExpire = onExpire
        onStatusChange(.running)
    }

    func update(fraction: Double, subtitle: String) {}

    func end(success: Bool) {
        guard let task else { return }
        self.task = nil
        onExpire = nil
        endTask(task)
    }

    /// iOS requires the task to end before the expiration handler returns.
    private func expire(_ expected: Int) {
        guard expected == generation, task != nil else { return }
        let handler = onExpire
        end(success: false)
        Self.log.info("stage=grace outcome=expired")
        handler?()
    }
}

#if canImport(UIKit) && !os(watchOS)
extension NarrationGraceTime {
    static func system() -> NarrationGraceTime {
        NarrationGraceTime(
            begin: { expire in
                let id = UIApplication.shared.beginBackgroundTask(withName: "Translation") {
                    MainActor.assumeIsolated { expire() }
                }
                return id == .invalid ? nil : id.rawValue
            },
            end: { UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: $0)) }
        )
    }
}
#endif
