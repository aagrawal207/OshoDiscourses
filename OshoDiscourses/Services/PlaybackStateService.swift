import Foundation
import Observation

@Observable
@MainActor
final class PlaybackStateService {

    private let defaults: UserDefaults
    private let recordListeningTime: @MainActor (TimeInterval) -> Void
    private let saveListeningStats: @MainActor () -> Void
    private let keyPrefix = "playbackPosition_"
    private let durationKeyPrefix = "playbackDuration_"
    /// When this device last moved a discourse's position, so a delayed Watch
    /// report cannot rewind listening done here afterwards.
    private let savedAtKeyPrefix = "playbackSavedAt_"
    private let recentKey = "recentlyPlayed"
    private let completedKey = "completedDiscourseIDs"
    private let playedKey = "allPlayedDiscourseIDs"
    private let maxRecent = 20

    private var autoSaveTask: Task<Void, Never>?
    private weak var audioPlayer: AudioPlayerService?
    private var lastRecordedTime: TimeInterval = 0
    private var lastRecordedTrackId: String?
    private var lastRecordedGeneration: UInt64?
    private var wasPlaying = false

    private(set) var recentlyPlayed: [String] = []
    private(set) var completedDiscourseIDs: Set<String> = []
    private(set) var listenedCompleted: [String] = []
    private(set) var allPlayedDiscourseIDs: [String] = []

    private let listenedCompletedKey = "listenedCompletedIDs"

    init(
        defaults: UserDefaults = .standard,
        recordListeningTime: @escaping @MainActor (TimeInterval) -> Void = { ListeningStatsService.shared.recordListeningTime($0) },
        saveListeningStats: @escaping @MainActor () -> Void = { ListeningStatsService.shared.save() }
    ) {
        self.defaults = defaults
        self.recordListeningTime = recordListeningTime
        self.saveListeningStats = saveListeningStats
        recentlyPlayed = defaults.stringArray(forKey: recentKey) ?? []
        if let saved = defaults.stringArray(forKey: completedKey) {
            completedDiscourseIDs = Set(saved)
        }
        listenedCompleted = defaults.stringArray(forKey: listenedCompletedKey) ?? []
        if defaults.object(forKey: playedKey) != nil {
            allPlayedDiscourseIDs = defaults.stringArray(forKey: playedKey) ?? []
        } else {
            migratePlayedHistory()
        }
    }

    /// Attach to an AudioPlayerService to enable auto-save every 10 seconds.
    func attach(to player: AudioPlayerService) {
        audioPlayer = player
        resetListeningContinuity()
        startAutoSave()
    }

    // MARK: - Public API

    /// `savedAt` records when the listening happened (a Watch report's time);
    /// nil means now, counted only when the position moved, since autosave also
    /// rewrites a paused position every tick.
    func savePosition(discourseId: String, position: TimeInterval, duration: TimeInterval = 0, savedAt: Date? = nil) {
        guard position.isFinite, position > 0 else { return }
        if let savedAt {
            recordSaveTime(savedAt, for: discourseId)
        } else if abs(getPosition(discourseId: discourseId) - position) >= 1 {
            recordSaveTime(Date(), for: discourseId)
        }
        storePosition(discourseId: discourseId, position: position, duration: duration)
    }

    private func storePosition(discourseId: String, position: TimeInterval, duration: TimeInterval) {
        defaults.set(position, forKey: keyPrefix + discourseId)
        if duration.isFinite, duration > 0 {
            defaults.set(duration, forKey: durationKeyPrefix + discourseId)
        }
    }

    func lastSaved(discourseId: String) -> Date? {
        let value = defaults.double(forKey: savedAtKeyPrefix + discourseId)
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }

    private func recordSaveTime(_ date: Date, for discourseId: String) {
        defaults.set(date.timeIntervalSince1970, forKey: savedAtKeyPrefix + discourseId)
    }

    func getPosition(discourseId: String) -> TimeInterval {
        return defaults.double(forKey: keyPrefix + discourseId)
    }

    func getDuration(discourseId: String) -> TimeInterval {
        return defaults.double(forKey: durationKeyPrefix + discourseId)
    }

    /// Keeps the save time: finishing or clearing a talk is also listening news.
    func clearPosition(discourseId: String, at date: Date = Date()) {
        recordSaveTime(date, for: discourseId)
        defaults.removeObject(forKey: keyPrefix + discourseId)
        defaults.removeObject(forKey: durationKeyPrefix + discourseId)
        recentlyPlayed.removeAll { $0 == discourseId }
        defaults.set(recentlyPlayed, forKey: recentKey)
    }

    func dismissFromRecent(discourseId: String) {
        recentlyPlayed.removeAll { $0 == discourseId }
        defaults.set(recentlyPlayed, forKey: recentKey)
    }

    func recordPlay(discourseId: String) {
        recentlyPlayed.removeAll { $0 == discourseId }
        recentlyPlayed.insert(discourseId, at: 0)
        if recentlyPlayed.count > maxRecent {
            recentlyPlayed = Array(recentlyPlayed.prefix(maxRecent))
        }
        defaults.set(recentlyPlayed, forKey: recentKey)
        recordInPlayedHistory(discourseId)
    }

    // MARK: - Completion Tracking

    func markCompleted(discourseId: String) {
        completedDiscourseIDs.insert(discourseId)
        defaults.set(Array(completedDiscourseIDs), forKey: completedKey)
        recordInPlayedHistory(discourseId)
    }

    func markListenedComplete(discourseId: String) {
        completedDiscourseIDs.insert(discourseId)
        defaults.set(Array(completedDiscourseIDs), forKey: completedKey)
        listenedCompleted.removeAll { $0 == discourseId }
        listenedCompleted.insert(discourseId, at: 0)
        if listenedCompleted.count > 20 {
            listenedCompleted = Array(listenedCompleted.prefix(20))
        }
        defaults.set(listenedCompleted, forKey: listenedCompletedKey)
        recordInPlayedHistory(discourseId)
    }

    func dismissListenedComplete(discourseId: String) {
        listenedCompleted.removeAll { $0 == discourseId }
        defaults.set(listenedCompleted, forKey: listenedCompletedKey)
    }

    func isCompleted(_ discourseId: String) -> Bool {
        completedDiscourseIDs.contains(discourseId)
    }

    func unmarkCompleted(discourseId: String) {
        completedDiscourseIDs.remove(discourseId)
        defaults.set(Array(completedDiscourseIDs), forKey: completedKey)
    }

    func completedCount(for seriesId: String) -> Int {
        completedDiscourseIDs.filter { $0.hasPrefix(seriesId + "-") }.count
    }

    // MARK: - iCloud Sync (NSUbiquitousKeyValueStore)

    /// Notified after a merge changes local progress (e.g. another device's
    /// data arrived) so the UI can refresh. Set by the app on startup.
    var onCloudMerge: (() -> Void)?

    /// Called after local progress is persisted (auto-save tick / detach) so the
    /// cloud sync can push. Set by the app on startup; nil keeps sync inert.
    var onProgressSaved: (() -> Void)?

    /// Build a bounded snapshot of progress to sync. Positions/durations are
    /// limited to the recently-played IDs so the payload stays small (KVS caps
    /// at 1 MB / 1024 keys); the completed set is sent in full since it's the
    /// data most worth preserving across devices.
    func exportCloudSnapshot() -> CloudSnapshot {
        var positions: [String: TimeInterval] = [:]
        var durations: [String: TimeInterval] = [:]
        for id in recentlyPlayed {
            let pos = getPosition(discourseId: id)
            if pos > 0 { positions[id] = pos }
            let dur = getDuration(discourseId: id)
            if dur > 0 { durations[id] = dur }
        }
        return CloudSnapshot(
            positions: positions,
            durations: durations,
            recentlyPlayed: recentlyPlayed,
            completed: Array(completedDiscourseIDs),
            listenedCompleted: listenedCompleted,
            played: allPlayedDiscourseIDs
        )
    }

    /// Merge a cloud snapshot into local state using convergent rules:
    /// - positions/durations: keep the larger value (never rewind a listener
    ///   who is further ahead on another device)
    /// - completed: union (completion is monotonic)
    /// - recency lists: cloud entries first, then local, deduped and capped
    /// Returns true if anything changed locally.
    @discardableResult
    func mergeCloudSnapshot(_ snapshot: CloudSnapshot) -> Bool {
        var changed = false

        for (id, cloudPos) in snapshot.positions
            where cloudPos.isFinite && cloudPos > getPosition(discourseId: id) {
            let cloudDur = snapshot.durations[id] ?? getDuration(discourseId: id)
            // Another device's listening; this device's save time stays unchanged.
            storePosition(discourseId: id, position: cloudPos, duration: cloudDur)
            if let player = audioPlayer, player.currentTrackId == id, !player.isPlaying {
                // Otherwise the paused player's next autosave writes its older position back.
                player.seek(to: cloudPos)
            }
            changed = true
        }
        for (id, cloudDur) in snapshot.durations
            where cloudDur.isFinite && cloudDur > getDuration(discourseId: id) {
            defaults.set(cloudDur, forKey: durationKeyPrefix + id)
            changed = true
        }

        let mergedCompleted = completedDiscourseIDs.union(snapshot.completed)
        if mergedCompleted != completedDiscourseIDs {
            completedDiscourseIDs = mergedCompleted
            defaults.set(Array(completedDiscourseIDs), forKey: completedKey)
            changed = true
        }

        let mergedRecent = Self.mergeList(
            cloud: snapshot.recentlyPlayed, local: recentlyPlayed, cap: maxRecent
        )
        if mergedRecent != recentlyPlayed {
            recentlyPlayed = mergedRecent
            defaults.set(recentlyPlayed, forKey: recentKey)
            changed = true
        }

        let mergedListened = Self.mergeList(
            cloud: snapshot.listenedCompleted, local: listenedCompleted, cap: 20
        )
        if mergedListened != listenedCompleted {
            listenedCompleted = mergedListened
            defaults.set(listenedCompleted, forKey: listenedCompletedKey)
            changed = true
        }

        let cloudPlayed = (snapshot.played ?? snapshot.recentlyPlayed + snapshot.completed)
        let mergedPlayed = Self.mergeList(
            cloud: cloudPlayed,
            local: allPlayedDiscourseIDs,
            cap: Int.max
        )
        if mergedPlayed != allPlayedDiscourseIDs {
            allPlayedDiscourseIDs = mergedPlayed
            defaults.set(allPlayedDiscourseIDs, forKey: playedKey)
            changed = true
        }

        if changed { onCloudMerge?() }
        return changed
    }

    /// Union two ordered recency lists, cloud entries first, deduped, capped.
    static func mergeList(cloud: [String], local: [String], cap: Int) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for id in cloud + local where !seen.contains(id) {
            seen.insert(id)
            result.append(id)
        }
        return Array(result.prefix(cap))
    }

    // MARK: - Private

    private func recordInPlayedHistory(_ discourseId: String) {
        allPlayedDiscourseIDs.removeAll { $0 == discourseId }
        allPlayedDiscourseIDs.insert(discourseId, at: 0)
        defaults.set(allPlayedDiscourseIDs, forKey: playedKey)
    }

    /// Older versions retained only 20 recent IDs, but kept positions for every
    /// discourse. Rebuild the uncapped history once, preserving known recency
    /// first and then recovering older positioned/completed catalog entries.
    private func migratePlayedHistory() {
        var seen = Set<String>()
        var migrated: [String] = []
        let knownRecent = recentlyPlayed + listenedCompleted
        for id in knownRecent where seen.insert(id).inserted {
            migrated.append(id)
        }
        for discourse in Catalog.allDiscourses() {
            let wasPlayed = defaults.double(forKey: keyPrefix + discourse.id) > 0
                || completedDiscourseIDs.contains(discourse.id)
            if wasPlayed && seen.insert(discourse.id).inserted {
                migrated.append(discourse.id)
            }
        }
        allPlayedDiscourseIDs = migrated
        defaults.set(migrated, forKey: playedKey)
    }

    func saveCurrentPosition() {
        guard let player = audioPlayer else {
            resetListeningContinuity()
            return
        }
        guard let trackId = player.currentTrackId,
              player.currentTime.isFinite, player.currentTime > 0 else {
            resetListeningContinuity()
            return
        }
        savePosition(discourseId: trackId, position: player.currentTime, duration: player.duration)

        // A listener can leave and return to the same recording between autosave ticks.
        if player.currentTrackId != lastRecordedTrackId || player.playbackGeneration != lastRecordedGeneration {
            lastRecordedTrackId = player.currentTrackId
            lastRecordedGeneration = player.playbackGeneration
            lastRecordedTime = player.currentTime
            wasPlaying = false
        }
        if player.isPlaying {
            let delta = player.currentTime - lastRecordedTime
            if wasPlaying && Self.isContinuousListening(delta: delta, rate: player.playbackRate) {
                recordListeningTime(delta)
            }
            lastRecordedTime = player.currentTime
            wasPlaying = true
        } else {
            wasPlaying = false
        }
        saveListeningStats()
        onProgressSaved?()
    }

    private func resetListeningContinuity() {
        lastRecordedTime = 0
        lastRecordedTrackId = nil
        lastRecordedGeneration = nil
        wasPlaying = false
    }

    /// Whether the media-position delta between two ~10s auto-save ticks is
    /// continuous listening (record it) or a seek (discard it). A 10s wall-time
    /// tick covers up to 10 × rate seconds of media, so the old fixed 15s cutoff
    /// silently discarded ALL listening at 1.5x+ speed. Threshold: one tick of
    /// media time at the current rate, plus 5s of tick jitter. Rates below 1x
    /// keep the 1x threshold — a slow tick never overshoots it.
    nonisolated static func isContinuousListening(delta: TimeInterval, rate: Float) -> Bool {
        delta > 0 && delta <= 10 * TimeInterval(max(rate, 1.0)) + 5
    }

    private func startAutoSave() {
        autoSaveTask?.cancel()
        autoSaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { break }
                guard let self else { return }
                self.saveCurrentPosition()
            }
        }
    }
}
