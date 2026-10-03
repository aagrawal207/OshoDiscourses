import Testing
import UIKit
@testable import OshoDiscourses

@MainActor
struct MacWindowConfiguratorTests {
    #if targetEnvironment(macCatalyst)
    @Test func hostWindowGetsMinimumSize() async throws {
        // The test host's own SwiftUI window can connect after the bundle loads.
        var scenes: [UIWindowScene] = []
        for _ in 0..<150 {
            scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .filter { $0.session.role == .windowApplication && $0.sizeRestrictions != nil }
            if !scenes.isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let states = UIApplication.shared.connectedScenes.map { "\($0.session.role.rawValue):\($0.activationState.rawValue)" }
        try #require(!scenes.isEmpty, "no window scene with size restrictions; scenes: \(states)")
        MacWindowConfigurator.install()
        for scene in scenes {
            #expect(scene.sizeRestrictions?.minimumSize == MacWindowConfigurator.minimumSize)
        }
    }
    #else
    @Test func installIsInertOffMac() {
        MacWindowConfigurator.install()
        let restricted = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .contains { $0.sizeRestrictions?.minimumSize == MacWindowConfigurator.minimumSize }
        #expect(!restricted)
    }
    #endif
}
