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
}

final class TelemetryDeckSink: TelemetrySink {
    var isTestSink: Bool { false }

    func start(appID: String, namespace: String, defaultParameters: @escaping @Sendable () -> [String: String]) {
        let config = TelemetryDeck.Config(appID: appID, namespace: namespace)
        config.defaultParameters = defaultParameters
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
