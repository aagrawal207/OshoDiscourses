import Foundation
import OSLog

/// When local listening is reported to the phone: always on pause, stop and finish; while playing,
/// at most once per interval, so `transferUserInfo` does not queue a report every few seconds.
struct PositionReportPolicy {
    enum Reason: Equatable { case tick, pause, finish }

    static let playingInterval: TimeInterval = 60

    private var lastReportAt: TimeInterval?

    /// Starting playback opens a fresh interval, so the first periodic report comes a minute in.
    mutating func playbackStarted(at uptime: TimeInterval) {
        lastReportAt = uptime
    }

    mutating func shouldReport(_ reason: Reason, at uptime: TimeInterval) -> Bool {
        switch reason {
        case .pause, .finish:
            lastReportAt = uptime
            return true
        case .tick:
            if let last = lastReportAt, uptime - last < Self.playingInterval { return false }
            lastReportAt = uptime
            return true
        }
    }
}

/// Sends reports through the session, keeping the newest per discourse until the session can take it.
@MainActor
final class PositionReporter {
    private let send: @MainActor (Data) -> Bool
    private(set) var unsent: [String: CompanionPositionReport] = [:]

    init(send: @escaping @MainActor (Data) -> Bool) {
        self.send = send
    }

    func report(_ report: CompanionPositionReport) {
        guard let data = try? CompanionWire.encode(report) else { return }
        if send(data) {
            unsent[report.discourseID] = nil
        } else {
            unsent[report.discourseID] = report
        }
    }

    func flush() {
        for report in unsent.values.sorted(by: { $0.recordedAt < $1.recordedAt }) {
            guard let data = try? CompanionWire.encode(report), send(data) else { return }
            unsent[report.discourseID] = nil
        }
    }
}

/// Saves local listening and reports it. A report carries the stored stamp and goes out only when the
/// stamp is new, so pausing or backgrounding without listening never resends an old position as newer.
@MainActor
final class ListeningRecorder {
    private let library: OfflineLibrary
    private let reporter: PositionReporter
    private let uptime: @MainActor () -> TimeInterval
    private let clock: @MainActor () -> Date
    private var policy = PositionReportPolicy()
    private var reportedStamp: Date?

    init(
        library: OfflineLibrary, reporter: PositionReporter,
        uptime: @escaping @MainActor () -> TimeInterval = { WatchClock.now },
        clock: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.library = library
        self.reporter = reporter
        self.uptime = uptime
        self.clock = clock
    }

    /// The loaded position is already known to whichever side stamped it.
    func load(_ entry: OfflineEntry) {
        reportedStamp = entry.positionUpdatedAt
    }

    func playbackStarted() {
        policy.playbackStarted(at: uptime())
    }

    @discardableResult
    func save(
        _ discourseID: String, position: Double, duration: Double?, finished: Bool,
        report reason: PositionReportPolicy.Reason?
    ) -> OfflineEntry? {
        library.savePosition(discourseID, position: position, duration: duration, finished: finished, at: clock())
        guard let saved = library.entry(for: discourseID) else { return nil }
        // The phone stores reports at their recorded time, so its echo of this one never reads as newer here.
        if let reason, let stamp = saved.positionUpdatedAt, stamp != reportedStamp,
           policy.shouldReport(reason, at: uptime()) {
            reportedStamp = stamp
            reporter.report(CompanionPositionReport(
                discourseID: discourseID, position: saved.position, duration: saved.duration,
                finished: saved.finished, recordedAt: stamp
            ))
        }
        return saved
    }
}
