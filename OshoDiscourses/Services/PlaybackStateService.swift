import Foundation
import Observation

@Observable
@MainActor
final class PlaybackStateService {

    private let defaults = UserDefaults.standard
    private let keyPrefix = "playbackPosition_"

    private var autoSaveTask: Task<Void, Never>?
    private weak var audioPlayer: AudioPlayerService?

    init() {}

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

    func savePosition(discourseId: String, position: TimeInterval) {
        guard position > 0 else { return }
        defaults.set(position, forKey: keyPrefix + discourseId)
    }

    func getPosition(discourseId: String) -> TimeInterval {
        defaults.double(forKey: keyPrefix + discourseId)
    }

    func clearPosition(discourseId: String) {
        defaults.removeObject(forKey: keyPrefix + discourseId)
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
        savePosition(discourseId: trackId, position: player.currentTime)
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
