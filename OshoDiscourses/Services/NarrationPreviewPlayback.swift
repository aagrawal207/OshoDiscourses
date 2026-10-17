import AVFoundation
import Foundation
import Observation
import os

/// Plays a narration while it is still being prepared, extending playback as later passages are saved.
@Observable
@MainActor
final class NarrationPreviewPlayback {
    static let shared: NarrationPreviewPlayback = NarrationPreviewPlayback(narrations: .shared)

    /// Playback reached the last finished passage; it continues when preparation saves the next one,
    /// including after preparation is paused and resumed.
    private var caughtUp: (documentID: String, passages: Int, position: TimeInterval, generation: UInt64, intent: UInt64)?
    private(set) var isLoading = false
    /// The rendition whose finished passages are being joined into a timeline right now.
    private(set) var loadingDocumentID: String?
    private(set) var failureMessage: String?

    @ObservationIgnored private let narrations: NarrationService
    @ObservationIgnored private weak var player: AudioPlayerService?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private let makeTimeline: @MainActor ([URL]) async throws -> AVMutableComposition
    private static let log = Logger(subsystem: "com.agraabhi.oshodiscourses", category: "NarrationPreview")

    init(narrations: NarrationService,
         makeTimeline: @escaping @MainActor ([URL]) async throws -> AVMutableComposition = { try await NarrationPreviewPlayback.timeline(joining: $0) }) {
        self.narrations = narrations
        self.makeTimeline = makeTimeline
    }

    /// Only shown while preparation is running; a paused preparation is not something to wait for.
    var waitingDocumentID: String? {
        guard let caughtUp, narrations.preparingDocumentID == caughtUp.documentID else { return nil }
        return caughtUp.documentID
    }

    /// Plays the complete narration when it exists, otherwise its finished passages.
    func play(documentID: String, player: AudioPlayerService, resumeAt position: TimeInterval? = nil) {
        attach(player)
        caughtUp = nil
        failureMessage = nil
        generation &+= 1
        loading?.cancel()
        loadingDocumentID = nil
        if let document = narrations.documents.first(where: { $0.id == documentID }), document.isComplete,
           let url = narrations.audioURL(for: document) {
            isLoading = false
            if let position { narrations.savePosition(documentID: documentID, position: position) }
            player.playNarration(document, url: url)
            Self.log.info("outcome=complete_narration")
            // Switching from finished passages to the joined file frees their files.
            Task { await narrations.removeSpentPassageAudio() }
            return
        }
        guard let prefix = narrations.playablePrefix(of: documentID), let first = prefix.segmentURLs.first else {
            isLoading = false
            failureMessage = "No translated passages are ready to play yet."
            Self.log.notice("outcome=nothing_ready")
            return
        }
        let started = generation
        let playbackGeneration = player.playbackGeneration
        let playbackIntent = player.playbackIntentGeneration
        isLoading = true
        loadingDocumentID = documentID
        loading = Task {
            defer { if started == generation { loadingDocumentID = nil } }
            do {
                let asset = try await makeTimeline(prefix.segmentURLs)
                guard started == generation, !Task.isCancelled else { return }
                isLoading = false
                guard player.playbackGeneration == playbackGeneration,
                      player.playbackIntentGeneration == playbackIntent else { return }
                player.playNarrationPreview(prefix.document, firstSegmentURL: first, asset: asset, resumeAt: position)
                Self.log.info("outcome=preview_started passages=\(prefix.document.segments.count, privacy: .public)")
            } catch {
                guard started == generation, !Task.isCancelled else { return }
                isLoading = false
                failureMessage = "The finished passages couldn't be played. Try again."
                Self.log.error("outcome=preview_failed")
            }
        }
    }

    /// Whether a saved translation still has audio: its joined file, or its finished passages on disk.
    func hasPlayableAudio(_ document: NarrationDocument) -> Bool {
        if let saved = narrations.documents.first(where: { $0.id == document.id }), saved.isComplete,
           narrations.audioURL(for: saved) != nil { return true }
        guard let prefix = narrations.playablePrefix(of: document.id) else { return false }
        return prefix.segmentURLs.allSatisfy { FileManager.default.isReadableFile(atPath: $0.path) }
    }

    /// Loads a saved translation paused at its saved position for relaunch restore, as `play`
    /// would load it. Returns false when it cannot be loaded, so restore can try the next row.
    func restore(documentID: String, player: AudioPlayerService) async -> Bool {
        guard player.currentTrackId == nil else { return false }
        if let document = narrations.documents.first(where: { $0.id == documentID }), document.isComplete,
           let url = narrations.audioURL(for: document) {
            attach(player)
            player.restoreNarration(document, url: url)
            return player.currentNarration?.id == documentID
        }
        guard let prefix = narrations.playablePrefix(of: documentID), let first = prefix.segmentURLs.first else { return false }
        let started = generation
        let playbackGeneration = player.playbackGeneration
        let playbackIntent = player.playbackIntentGeneration
        guard let asset = try? await makeTimeline(prefix.segmentURLs) else {
            Self.log.notice("outcome=restore_failed")
            return false
        }
        // Anything the listener started while the passages were joined wins.
        guard started == generation, player.currentTrackId == nil,
              player.playbackGeneration == playbackGeneration,
              player.playbackIntentGeneration == playbackIntent else { return false }
        attach(player)
        player.restoreNarration(prefix.document, url: first, joinedPassages: asset)
        Self.log.info("outcome=preview_restored passages=\(prefix.document.segments.count, privacy: .public)")
        return player.currentNarration?.id == documentID
    }

    func stopWaiting() {
        caughtUp = nil
        generation &+= 1
        loading?.cancel()
        isLoading = false
        loadingDocumentID = nil
    }

    /// Before a rendition is deleted, so no timeline is built from passage files about to disappear.
    func stopLoading(documentID: String) {
        if loadingDocumentID == documentID || caughtUp?.documentID == documentID { stopWaiting() }
    }

    private func attach(_ player: AudioPlayerService) {
        guard self.player !== player || player.onNarrationPreviewEnd == nil else { return }
        self.player = player
        player.onNarrationPreviewEnd = { [weak self] document in self?.reachedEnd(of: document) }
        narrations.onEvent = { [weak self] event in self?.handle(event) }
    }

    private func reachedEnd(of document: NarrationDocument) {
        guard let player, player.currentNarration?.id == document.id else { return }
        let latest = narrations.documents.first { $0.id == document.id }
        let available = narrations.playablePrefix(of: document.id)?.document.segments.count ?? 0
        if let latest, latest.isComplete, document.segments.count >= latest.segments.count {
            // Every passage has been heard; finish like a complete narration rather than replaying it.
            caughtUp = nil
            player.stop()
            narrations.savePosition(documentID: document.id, position: 0)
            SleepTimerService.shared.discourseDidFinish()
            Self.log.info("outcome=finished")
            Task { await narrations.removeSpentPassageAudio() }
        } else if latest?.isComplete == true || available > document.segments.count {
            play(documentID: document.id, player: player, resumeAt: document.duration)
        } else {
            caughtUp = (document.id, document.segments.count, document.duration, player.playbackGeneration, player.playbackIntentGeneration)
            Self.log.info("outcome=caught_up preparing=\(self.narrations.preparingDocumentID == document.id, privacy: .public)")
        }
    }

    private func handle(_ event: NarrationService.Event) {
        switch event {
        case .documentUpdated(let document):
            // Resuming preparation republishes the saved passages; only a new one continues playback.
            guard let caughtUp, caughtUp.documentID == document.id,
                  (narrations.playablePrefix(of: document.id)?.document.segments.count ?? 0) > caughtUp.passages else { return }
            guard let player, player.currentNarration?.id == document.id, !player.isPlaying,
                  player.playbackGeneration == caughtUp.generation,
                  player.playbackIntentGeneration == caughtUp.intent,
                  abs(player.currentTime - caughtUp.position) < 1 else {
                // The listener moved on, so a newly saved passage must not start playback.
                self.caughtUp = nil
                return
            }
            play(documentID: document.id, player: player, resumeAt: caughtUp.position)
        case .preparationEnded:
            break
        }
    }

    /// Joins saved passage files without re-encoding, so building the timeline takes a moment rather than minutes.
    static func timeline(joining urls: [URL]) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        guard let destination = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw NativeNarrationSpeechError.exportUnavailable }
        var assets: [AVURLAsset] = []
        var tracks: [AVAssetTrack] = []
        var ranges: [NSValue] = []
        for url in urls {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                throw NativeNarrationSpeechError.invalidSegment
            }
            let range = try await track.load(.timeRange)
            guard range.isValid, range.duration.isNumeric, range.duration.seconds > 0 else {
                throw NativeNarrationSpeechError.invalidSegment
            }
            assets.append(asset)
            tracks.append(track)
            ranges.append(NSValue(timeRange: range))
        }
        // AVAssetTrack.asset is weak; source assets must survive until insertion copies the edits.
        try withExtendedLifetime(assets) {
            try destination.insertTimeRanges(ranges, of: tracks, at: .zero)
        }
        return composition
    }
}
