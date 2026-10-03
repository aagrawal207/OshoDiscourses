#if canImport(CarPlay) && !targetEnvironment(macCatalyst)
import CarPlay
import Foundation

/// Submits one native navigation at a time and only ever continues the newest
/// intent, so a late completion cannot push a screen the driver moved away from.
@MainActor
final class CarPlayTemplateNavigator {
    /// CarPlay audio apps allow five templates per stack, root included.
    static let maximumDepth = 5

    private struct Destination {
        let id = UUID()
        let template: CPTemplate
        let onFailure: @MainActor (String) -> Void
    }

    private let interface: any CarPlayInterfaceTransport
    private var generation = UUID()
    private var operation: UUID?
    private var destination: Destination?
    private var rootIsReady = false
    private(set) var isConnected = false
    var isChangingTemplates: Bool { operation != nil }

    init(interface: any CarPlayInterfaceTransport) { self.interface = interface }

    func installRoot(_ template: CPTemplate, onFailure: @escaping @MainActor (String) -> Void) {
        generation = UUID()
        isConnected = true
        rootIsReady = false
        destination = nil
        let connection = generation
        let work = UUID()
        operation = work
        interface.setRoot(template) { [weak self] success, message in
            guard let self, self.isConnected, self.generation == connection, self.operation == work else { return }
            self.operation = nil
            self.rootIsReady = success
            if success { self.advance() } else { onFailure(message ?? "CarPlay couldn't open Osho Talks.") }
        }
    }

    func show(_ template: CPTemplate, onFailure: @escaping @MainActor (String) -> Void) {
        guard isConnected else { return }
        destination = Destination(template: template, onFailure: onFailure)
        advance()
    }

    /// The driver navigated natively (tab change, back); a queued destination is abandoned.
    func userChangedNavigation() {
        destination = nil
    }

    func disconnect() {
        isConnected = false
        generation = UUID()
        operation = nil
        destination = nil
        rootIsReady = false
    }

    private func advance() {
        guard isConnected, rootIsReady, operation == nil, let destination else { return }
        if interface.topTemplate === destination.template {
            self.destination = nil
            return
        }
        let stack = interface.templates
        if stack.contains(where: { $0 === destination.template }) {
            perform(destination, finishesDestination: true) { interface.pop(to: destination.template, completion: $0) }
        } else if stack.count >= Self.maximumDepth {
            perform(destination, finishesDestination: false) { interface.popToRoot(completion: $0) }
        } else {
            perform(destination, finishesDestination: true) { interface.push(destination.template, completion: $0) }
        }
    }

    private func perform(_ target: Destination, finishesDestination: Bool,
                         submit: (@escaping CarPlayInterfaceCompletion) -> Void) {
        let connection = generation
        let work = UUID()
        operation = work
        submit { [weak self] success, message in
            guard let self, self.isConnected, self.generation == connection, self.operation == work else { return }
            self.operation = nil
            if self.destination?.id == target.id {
                if !success {
                    self.destination = nil
                    target.onFailure(message ?? "CarPlay couldn't open this screen. Try again.")
                } else if finishesDestination {
                    self.destination = nil
                }
            }
            self.advance()
        }
    }
}
#endif
