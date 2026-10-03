#if canImport(WatchConnectivity) && !targetEnvironment(macCatalyst)
import Foundation
import OSLog

/// Applies listening the Watch did offline to the phone's saved progress.
@MainActor
final class WatchPositionMerger {
    enum Outcome: String, Equatable, Sendable {
        case applied
        case completed
        case ignoredMalformed
        case ignoredUnknownDiscourse
        case ignoredInvalidPosition
        case ignoredOlder
        case ignoredPhoneNewer
        case ignoredPlayingOnPhone
        case caughtUpPlayingPhone
    }

    /// The discourse the phone's player has loaded, if any.
    struct LoadedDiscourse: Equatable, Sendable {
        var discourseID: String
        var isPlaying: Bool
        /// The current play stretch, while playing.
        var playingSince: Date? = nil
        var resumedFrom: TimeInterval? = nil
        /// The phone's save time for this discourse before the current stretch began.
        var savedBeforeResume: Date? = nil
    }

    /// A report can only arrive once the phone app runs, often because the listener
    /// just pressed play there; within this window it still moves the playing talk.
    static let catchUpWindow: TimeInterval = 60
    /// Smaller gains are not worth an audible jump.
    static let catchUpMinimumGain: TimeInterval = 5

    static let appliedKey = "watch.positionApplied.v1"
    private static let maximumRemembered = 200

    private let playbackState: PlaybackStateService
    private let loaded: @MainActor () -> LoadedDiscourse?
    private let moveLoadedPlayer: @MainActor (TimeInterval) -> Void
    private let unloadLoadedPlayer: @MainActor () -> Void
    private let now: @MainActor () -> Date
    private let defaults: UserDefaults
    /// discourseID -> recordedAt of the newest report applied, so a delayed older report can't rewind.
    private var applied: [String: Date]

    /// `moveLoadedPlayer` moves the loaded player to an applied position; otherwise
    /// its autosave would write the old position straight back. `unloadLoadedPlayer`
    /// mirrors a natural finish for a paused talk the Watch finished.
    init(
        playbackState: PlaybackStateService, defaults: UserDefaults = .standard,
        loaded: @escaping @MainActor () -> LoadedDiscourse?,
        moveLoadedPlayer: @escaping @MainActor (TimeInterval) -> Void = { _ in },
        unloadLoadedPlayer: @escaping @MainActor () -> Void = {},
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.playbackState = playbackState
        self.defaults = defaults
        self.loaded = loaded
        self.moveLoadedPlayer = moveLoadedPlayer
        self.unloadLoadedPlayer = unloadLoadedPlayer
        self.now = now
        let stored = defaults.dictionary(forKey: Self.appliedKey) as? [String: Double] ?? [:]
        applied = stored.mapValues { Date(timeIntervalSince1970: $0) }
    }

    @discardableResult
    func apply(_ data: Data) -> Outcome {
        guard let report = try? CompanionWire.decode(CompanionPositionReport.self, from: data) else {
            return log(.ignoredMalformed)
        }
        return apply(report)
    }

    @discardableResult
    func apply(_ report: CompanionPositionReport) -> Outcome {
        let id = report.discourseID
        guard Catalog.discourseLookup[id] != nil else { return log(.ignoredUnknownDiscourse) }
        guard report.position.isFinite, report.duration.isFinite, report.position >= 0, report.duration >= 0 else {
            return log(.ignoredInvalidPosition)
        }
        if let last = applied[id], report.recordedAt <= last { return log(.ignoredOlder) }
        let loadedHere = loaded().flatMap { $0.discourseID == id ? $0 : nil }
        if let loadedHere, loadedHere.isPlaying { return catchUp(loadedHere, with: report) }
        // Reports arrive late and only once; listening done on the phone since then wins.
        if let phoneSave = playbackState.lastSaved(discourseId: id), report.recordedAt <= phoneSave {
            return log(.ignoredPhoneNewer)
        }

        let outcome: Outcome
        if report.finished {
            // Mirrors a natural finish on the phone: completed, and dropped from Continue Listening.
            playbackState.markListenedComplete(discourseId: id)
            playbackState.clearPosition(discourseId: id, at: report.recordedAt)
            if loadedHere != nil { unloadLoadedPlayer() }
            outcome = .completed
        } else {
            guard report.position > 0 else { return log(.ignoredInvalidPosition) }
            playbackState.savePosition(
                discourseId: id, position: report.position, duration: report.duration, savedAt: report.recordedAt
            )
            playbackState.recordPlay(discourseId: id)
            if loadedHere != nil { moveLoadedPlayer(report.position) }
            outcome = .applied
        }
        remember(id, report.recordedAt)
        playbackState.onProgressSaved?()
        return log(outcome)
    }

    func lastApplied(for discourseID: String) -> Date? { applied[discourseID] }

    /// Listening on the phone right now normally wins. The exception is a stretch
    /// that only just resumed from an older point than the Watch reached.
    private func catchUp(_ loaded: LoadedDiscourse, with report: CompanionPositionReport) -> Outcome {
        guard !report.finished,
              let since = loaded.playingSince, report.recordedAt < since,
              now().timeIntervalSince(since) <= Self.catchUpWindow,
              report.position >= (loaded.resumedFrom ?? 0) + Self.catchUpMinimumGain,
              loaded.savedBeforeResume.map({ report.recordedAt > $0 }) ?? true
        else { return log(.ignoredPlayingOnPhone) }
        remember(loaded.discourseID, report.recordedAt)
        moveLoadedPlayer(report.position)
        return log(.caughtUpPlayingPhone)
    }

    private func remember(_ id: String, _ date: Date) {
        applied[id] = date
        if applied.count > Self.maximumRemembered {
            let oldest = applied.sorted { $0.value < $1.value }.prefix(applied.count - Self.maximumRemembered)
            for (key, _) in oldest { applied[key] = nil }
        }
        defaults.set(applied.mapValues(\.timeIntervalSince1970), forKey: Self.appliedKey)
    }

    private func log(_ outcome: Outcome) -> Outcome {
        Logger.watchSession.info("position report \(outcome.rawValue, privacy: .public)")
        return outcome
    }
}
#endif
