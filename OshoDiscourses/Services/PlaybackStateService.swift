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
