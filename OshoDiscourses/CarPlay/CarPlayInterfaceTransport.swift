#if canImport(CarPlay) && !targetEnvironment(macCatalyst)
import CarPlay
import Foundation

typealias CarPlayInterfaceCompletion = @MainActor @Sendable (Bool, String?) -> Void

/// The slice of `CPInterfaceController` the session uses, so tests can drive
/// navigation and delayed completions without a head unit.
@MainActor
protocol CarPlayInterfaceTransport: AnyObject {
    var delegate: (any CPInterfaceControllerDelegate)? { get set }
    var templates: [CPTemplate] { get }
    var topTemplate: CPTemplate? { get }
    var presentedTemplate: CPTemplate? { get }

    func setRoot(_ template: CPTemplate, completion: @escaping CarPlayInterfaceCompletion)
    func push(_ template: CPTemplate, completion: @escaping CarPlayInterfaceCompletion)
    func pop(to template: CPTemplate, completion: @escaping CarPlayInterfaceCompletion)
    func popToRoot(completion: @escaping CarPlayInterfaceCompletion)
    func present(_ template: CPTemplate, completion: @escaping CarPlayInterfaceCompletion)
    func dismissPresented(completion: @escaping CarPlayInterfaceCompletion)
}

@MainActor
final class CarPlayNativeInterface: CarPlayInterfaceTransport {
    let controller: CPInterfaceController

    init(_ controller: CPInterfaceController) { self.controller = controller }

    var delegate: (any CPInterfaceControllerDelegate)? {
        get { controller.delegate }
        set { controller.delegate = newValue }
    }

    var templates: [CPTemplate] { controller.templates }
    var topTemplate: CPTemplate? { controller.topTemplate }
    var presentedTemplate: CPTemplate? { controller.presentedTemplate }

    func setRoot(_ template: CPTemplate, completion: @escaping CarPlayInterfaceCompletion) {
        controller.setRootTemplate(template, animated: false, completion: Self.callback(completion))
    }

    func push(_ template: CPTemplate, completion: @escaping CarPlayInterfaceCompletion) {
        controller.pushTemplate(template, animated: true, completion: Self.callback(completion))
    }

    func pop(to template: CPTemplate, completion: @escaping CarPlayInterfaceCompletion) {
        controller.pop(to: template, animated: true, completion: Self.callback(completion))
    }

    func popToRoot(completion: @escaping CarPlayInterfaceCompletion) {
        controller.popToRootTemplate(animated: true, completion: Self.callback(completion))
    }

    func present(_ template: CPTemplate, completion: @escaping CarPlayInterfaceCompletion) {
        controller.presentTemplate(template, animated: true, completion: Self.callback(completion))
    }

    func dismissPresented(completion: @escaping CarPlayInterfaceCompletion) {
        controller.dismissTemplate(animated: true, completion: Self.callback(completion))
    }

    nonisolated static func callback(_ completion: @escaping CarPlayInterfaceCompletion) -> @Sendable (Bool, Error?) -> Void {
        // Interface completions, unlike list-item handlers, have no documented main-queue guarantee.
        { @Sendable success, error in
            let message = error?.localizedDescription
            Task { @MainActor in completion(success, message) }
        }
    }
}
#endif
