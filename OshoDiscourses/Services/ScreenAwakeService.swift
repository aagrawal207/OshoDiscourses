import Foundation
import UIKit
import os

@MainActor
final class ScreenAwakeService {
    static let shared = ScreenAwakeService { UIApplication.shared.isIdleTimerDisabled = $0 }

    private var owners: Set<UUID> = []
    private let apply: @MainActor (Bool) -> Void
    private static let log = Logger(subsystem: "com.agraabhi.oshodiscourses", category: "ScreenAwake")

    init(apply: @escaping @MainActor (Bool) -> Void) {
        self.apply = apply
    }

    func setAwake(_ enabled: Bool, owner: UUID) {
        let wasAwake = !owners.isEmpty
        if enabled { owners.insert(owner) } else { owners.remove(owner) }
        update(wasAwake: wasAwake)
    }

    func removeAllRequests() {
        let wasAwake = !owners.isEmpty
        owners.removeAll()
        update(wasAwake: wasAwake)
    }

    private func update(wasAwake: Bool) {
        let awake = !owners.isEmpty
        guard awake != wasAwake else { return }
        apply(awake)
        Self.log.debug("Screen awake enabled=\(awake, privacy: .public)")
    }
}
