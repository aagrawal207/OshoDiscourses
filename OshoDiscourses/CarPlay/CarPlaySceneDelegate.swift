#if canImport(CarPlay) && !targetEnvironment(macCatalyst)
import CarPlay
import UIKit

/// Named in the Info.plist scene manifest as `$(PRODUCT_MODULE_NAME).CarPlaySceneDelegate`.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var session: CarPlaySessionController?
    private weak var connectedInterface: CPInterfaceController?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        // A CarPlay-only cold launch still runs App.init first; start() is idempotent.
        AppRuntime.shared.start()
        session?.disconnect()
        connectedInterface = interfaceController
        let session = CarPlaySessionController(
            interface: CarPlayNativeInterface(interfaceController),
            source: CarPlayRuntimeSource(runtime: AppRuntime.shared)
        )
        self.session = session
        session.connect()
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        guard connectedInterface === interfaceController else { return }
        session?.disconnect()
        session = nil
        connectedInterface = nil
    }
}
#endif
