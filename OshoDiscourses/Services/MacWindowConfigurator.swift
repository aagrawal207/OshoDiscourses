import UIKit
import os

/// Mac window limits for every app scene. Call `install()` once at launch
/// (App.init or the app delegate); it is a no-op on iPhone and iPad.
@MainActor
enum MacWindowConfigurator {
    /// Below this the sidebar, list and player columns stop fitting side by side.
    static let minimumSize = CGSize(width: 900, height: 600)

    private static var observers: [NSObjectProtocol] = []
    private static let log = Logger(subsystem: "com.agraabhi.oshodiscourses", category: "MacWindow")

    static func install() {
        #if targetEnvironment(macCatalyst)
        guard observers.isEmpty else { return }
        // SwiftUI creates scenes after App.init, so catch each one as it connects;
        // sizeRestrictions is nil until the scene has a Mac window behind it.
        for name in [UIScene.willConnectNotification, UIScene.didActivateNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { notification in
                let scene = notification.object as? UIWindowScene
                MainActor.assumeIsolated {
                    if let scene { apply(to: scene) }
                }
            })
        }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            apply(to: scene)
        }
        #endif
    }

    static func apply(to scene: UIWindowScene) {
        #if targetEnvironment(macCatalyst)
        // CarPlay template scenes are not UIWindowScenes with Mac windows.
        guard scene.session.role == .windowApplication,
              let restrictions = scene.sizeRestrictions else { return }
        if restrictions.minimumSize != minimumSize {
            restrictions.minimumSize = minimumSize
            log.info("outcome=minimum_size_applied")
        }
        #endif
    }
}
