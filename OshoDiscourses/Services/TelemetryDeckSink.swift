import Foundation
import StoreKit
import TelemetryDeck

/// Where signals go. Production sends to TelemetryDeck; tests record them.
@MainActor
protocol TelemetrySink: AnyObject {
    /// Test sinks may run inside the unit-test host; the real one never does.
    var isTestSink: Bool { get }
    func start(appID: String, namespace: String, defaultParameters: @escaping @Sendable () -> [String: String])
    func stop()
    func send(_ name: String, parameters: [String: String], floatValue: Double?)
    func purchaseCompleted(_ transaction: Transaction, parameters: [String: String])
    /// Every recorded event, before counting. Only test sinks look at it.
    func noteEvent(_ name: String, parameters: [String: String], floatValue: Double?)
}

extension TelemetrySink {
    func noteEvent(_ name: String, parameters: [String: String], floatValue: Double?) {}
}

final class TelemetryDeckSink: TelemetrySink {
    var isTestSink: Bool { false }

    func start(appID: String, namespace: String, defaultParameters: @escaping @Sendable () -> [String: String]) {
        let config = TelemetryDeck.Config(appID: appID, namespace: namespace)
        config.defaultParameters = defaultParameters
        // A signal on every foreground would cost more than the daily summary it duplicates.
        config.sendNewSessionBeganSignal = false
        TelemetryDeck.initialize(config: config)
    }

    func stop() {
        TelemetryDeck.terminate()
    }

    func send(_ name: String, parameters: [String: String], floatValue: Double?) {
        TelemetryDeck.signal(name, parameters: parameters, floatValue: floatValue)
    }

    func purchaseCompleted(_ transaction: Transaction, parameters: [String: String]) {
        TelemetryDeck.purchaseCompleted(transaction: transaction, parameters: parameters)
    }
}
