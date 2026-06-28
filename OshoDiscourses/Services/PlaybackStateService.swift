import Foundation
import Observation

@Observable
@MainActor
final class PlaybackStateService {

    private let defaults = UserDefaults.standard
    private let keyPrefix = "playbackPosition_"
    private let durationKeyPrefix = "playbackDuration_"
    private let recentKey = "recentlyPlayed"
    private let completedKey = "completedDiscourseIDs"
    private let maxRecent = 20

    private var autoSaveTask: Task<Void, Never>?
    private weak var audioPlayer: AudioPlayerService?
    private var lastRecordedTime: TimeInterval = 0
    private var lastRecordedTrackId: String?
    private var wasPlaying = false

    private(set) var recentlyPlayed: [String] = []
    private(set) var completedDiscourseIDs: Set<String> = []
    private(set) var listenedCompleted: [String] = []

    private let listenedCompletedKey = "listenedCompletedIDs"

    init() {
        recentlyPlayed = defaults.stringArray(forKey: recentKey) ?? []
        if let saved = defaults.stringArray(forKey: completedKey) {
            completedDiscourseIDs = Set(saved)
        }
        listenedCompleted = defaults.stringArray(forKey: listenedCompletedKey) ?? []
    }

    /// Attach to an AudioPlayerService to enable auto-save every 10 seconds.
    func attach(to player: AudioPlayerService) {
        audioPlayer = player
        startAutoSave()
    }

    /// Stop auto-saving (call when playback stops or view disappears).
    func detach() {
        autoSaveTask?.cancel()
        autoSaveTask = nil
        // Save one final time before detaching
        saveCurrentPosition()
    }

    // MARK: - Public API

    func savePosition(discourseId: String, position: TimeInterval, duration: TimeInterval = 0) {
        guard position > 0 else { return }
        defaults.set(position, forKey: keyPrefix + discourseId)
        if duration > 0 {
            defaults.set(duration, forKey: durationKeyPrefix + discourseId)
        }
    }

    func getPosition(discourseId: String) -> TimeInterval {
        defaults.double(forKey: keyPrefix + discourseId)
    }

    func getDuration(discourseId: String) -> TimeInterval {
        defaults.double(forKey: durationKeyPrefix + discourseId)
    }

    func clearPosition(discourseId: String) {
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
    }

    // MARK: - Completion Tracking

    func markCompleted(discourseId: String) {
        completedDiscourseIDs.insert(discourseId)
        defaults.set(Array(completedDiscourseIDs), forKey: completedKey)
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
            listenedCompleted: listenedCompleted
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

        for (id, cloudPos) in snapshot.positions where cloudPos > getPosition(discourseId: id) {
            let cloudDur = snapshot.durations[id] ?? getDuration(discourseId: id)
            savePosition(discourseId: id, position: cloudPos, duration: cloudDur)
            changed = true
        }
        for (id, cloudDur) in snapshot.durations where cloudDur > getDuration(discourseId: id) {
            defaults.set(cloudDur, forKey: durationKeyPrefix + id)
            changed = true
        }

        let mergedCompleted = completedDiscourseIDs.union(snapshot.completed)
        if mergedCompleted != completedDiscourseIDs {
            completedDiscourseIDs = mergedCompleted
            defaults.set(Array(completedDiscourseIDs), forKey: completedKey)
            changed = true
        }

        let mergedRecent = Self.mergeList(cloud: snapshot.recentlyPlayed, local: recentlyPlayed, cap: maxRecent)
        if mergedRecent != recentlyPlayed {
            recentlyPlayed = mergedRecent
            defaults.set(recentlyPlayed, forKey: recentKey)
            changed = true
        }

        let mergedListened = Self.mergeList(cloud: snapshot.listenedCompleted, local: listenedCompleted, cap: 20)
        if mergedListened != listenedCompleted {
            listenedCompleted = mergedListened
            defaults.set(listenedCompleted, forKey: listenedCompletedKey)
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

    /// Returns all saved discourse IDs with their positions.
    func allSavedPositions() -> [String: TimeInterval] {
        let allKeys = defaults.dictionaryRepresentation().keys
        var result = [String: TimeInterval]()
        for key in allKeys where key.hasPrefix(keyPrefix) {
            let id = String(key.dropFirst(keyPrefix.count))
            let position = defaults.double(forKey: key)
            if position > 0 {
                result[id] = position
            }
        }
        return result
    }

    // MARK: - Private

    private func saveCurrentPosition() {
        guard let player = audioPlayer,
              let trackId = player.currentTrackId,
              player.currentTime > 0 else { return }
        savePosition(discourseId: trackId, position: player.currentTime, duration: player.duration)

        // Track listening stats — reset if track changed
        let stats = ListeningStatsService.shared
        if player.currentTrackId != lastRecordedTrackId {
            lastRecordedTrackId = player.currentTrackId
            lastRecordedTime = player.currentTime
            wasPlaying = false
        }
        if player.isPlaying {
            let delta = player.currentTime - lastRecordedTime
            if wasPlaying && delta > 0 && delta <= 15 {
                // Only record continuous listening; delta > 15s indicates a seek
                stats.recordListeningTime(delta)
            }
            lastRecordedTime = player.currentTime
            wasPlaying = true
        } else {
            wasPlaying = false
        }
        stats.save()
        onProgressSaved?()
    }

    private func startAutoSave() {
        autoSaveTask?.cancel()
        autoSaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { break }
                self?.saveCurrentPosition()
            }
        }
    }
}
