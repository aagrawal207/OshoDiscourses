import Foundation
import StoreKit
import Testing
@testable import OshoDiscourses

/// Records signals instead of sending them. Shared by every telemetry test.
final class RecordingTelemetrySink: TelemetrySink {
    struct Signal: Equatable {
        let name: String
        let parameters: [String: String]
        let value: Double?
    }

    let isTestSink: Bool
    private(set) var signals: [Signal] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var namespace: String?
    private(set) var defaultParameters: (@Sendable () -> [String: String])?

    init(isTestSink: Bool = true) {
        self.isTestSink = isTestSink
    }

    func start(appID: String, namespace: String, defaultParameters: @escaping @Sendable () -> [String: String]) {
        startCount += 1
        self.namespace = namespace
        self.defaultParameters = defaultParameters
    }

    func stop() { stopCount += 1 }

    func send(_ name: String, parameters: [String: String], floatValue: Double?) {
        signals.append(Signal(name: name, parameters: parameters, value: floatValue))
    }

    func purchaseCompleted(_ transaction: Transaction, parameters: [String: String]) {
        signals.append(Signal(name: "TelemetryDeck.Purchase.completed", parameters: parameters, value: nil))
    }

    func named(_ signal: TelemetrySignal) -> [Signal] {
        signals.filter { $0.name == signal.rawValue }
    }
}

/// Runs `body` with the shared service sending to a recording sink, as the
/// app's services do, and restores it afterwards.
@MainActor
func withSharedTelemetry(_ body: (RecordingTelemetrySink) throws -> Void) rethrows {
    let sink = RecordingTelemetrySink()
    TelemetryService.shared.installTestSink(sink)
    defer { TelemetryService.shared.removeTestSink() }
    try body(sink)
}

@MainActor
func withSharedTelemetry(_ body: (RecordingTelemetrySink) async throws -> Void) async rethrows {
    let sink = RecordingTelemetrySink()
    TelemetryService.shared.installTestSink(sink)
    defer { TelemetryService.shared.removeTestSink() }
    try await body(sink)
}

/// Parent of every suite that installs the shared sink, so those suites never
/// run at the same time and swap the sink under each other.
@Suite(.serialized)
@MainActor
struct SharedTelemetrySuites {}
