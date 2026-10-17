import Foundation

/// Home's Continue Listening order: recordings and saved translations together, most
/// recent first. Relaunch restore walks the same rows, so it brings back Home's first row.
@MainActor
enum ContinueListening {
    enum Row: Equatable {
        case recording(String)
        case translation(NarrationDocument)

        var trackID: String {
            switch self {
            case .recording(let discourseID): discourseID
            case .translation(let document): AudioPlayerService.narrationTrackID(for: document.id)
            }
        }

        var discourseID: String {
            switch self {
            case .recording(let discourseID): discourseID
            case .translation(let document): document.discourseID
            }
        }
    }

    static func rows(
        playbackState: PlaybackStateService, narrations: NarrationService,
        isDownloaded: (String) -> Bool, currentTrackID: String?
    ) -> [Row] {
        let recordings = playbackState.continueListeningIDs(isDownloaded: isDownloaded, currentTrackID: currentTrackID)
        // Ties break by ID so Home and restore, which compute this separately, agree.
        let translations = narrations.recentPlays
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .compactMap { id, playedAt -> (document: NarrationDocument, playedAt: Date)? in
                guard let document = narrations.documents.first(where: { $0.id == id }),
                      Catalog.discourseLookup[document.discourseID] != nil,
                      narrations.position(for: id) > 0 || currentTrackID == AudioPlayerService.narrationTrackID(for: id)
                else { return nil }
                return (document, playedAt)
            }
        guard !translations.isEmpty else { return recordings.map(Row.recording) }
        // Recordings saved before last-listened times existed sort last.
        var merged: [Row] = []
        var pending = translations[...]
        for id in recordings {
            let saved = playbackState.lastSaved(discourseId: id) ?? .distantPast
            while let next = pending.first, next.playedAt > saved {
                merged.append(.translation(next.document))
                pending = pending.dropFirst()
            }
            merged.append(.recording(id))
        }
        merged += pending.map { .translation($0.document) }
        return merged
    }

    /// The rows a cold launch tries, in order. A row whose saved audio is gone is skipped,
    /// so the next one returns instead, as Home drops an evicted download.
    static func restoreCandidates(
        _ rows: [Row], hasFile: (String) -> Bool, hasNarrationAudio: (NarrationDocument) -> Bool
    ) -> [Row] {
        rows.filter { row in
            switch row {
            case .recording(let discourseID): hasFile(discourseID)
            case .translation(let document): hasNarrationAudio(document)
            }
        }
    }
}
