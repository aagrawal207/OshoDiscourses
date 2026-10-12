#if TRANSLATED_NARRATION
import Foundation

/// Listening to a series through translation instead of its recording. The choice is per series,
/// and a series in a language the listener has hidden starts out translated.
enum TranslatedListening {
    private static let preferenceKey = "narration.translatedSeries"

    /// The app's two catalog languages translate into each other; the sheet still offers others.
    static func targetLanguage(for series: SeriesInfo) -> String {
        series.language == .english ? "hi" : "en"
    }

    static func targetName(for series: SeriesInfo) -> String {
        NarrationLanguageSupport.displayName(for: targetLanguage(for: series))
    }

    static func originalName(for series: SeriesInfo) -> String {
        NarrationLanguageSupport.displayName(for: NarrationLanguageSupport.sourceLanguage(for: series.language))
    }

    static var isSupported: Bool {
        if #available(macCatalyst 26.0, *) { return true }
        return false
    }

    static func canTranslate(_ series: SeriesInfo) -> Bool {
        isSupported && TranscriptCatalog.transcriptCount(forSeriesID: series.id) > 0
    }

    static func isHidden(_ series: SeriesInfo, filter: LanguageFilter) -> Bool {
        switch filter {
        case .english: series.language == .hindi
        case .hindi: series.language == .english
        default: false
        }
    }

    static func prefersTranslation(_ series: SeriesInfo, filter: LanguageFilter, defaults: UserDefaults = .standard) -> Bool {
        guard canTranslate(series) else { return false }
        let stored = defaults.dictionary(forKey: preferenceKey) as? [String: Bool] ?? [:]
        return stored[series.id] ?? isHidden(series, filter: filter)
    }

    static func setPrefersTranslation(_ value: Bool, for series: SeriesInfo, defaults: UserDefaults = .standard) {
        var stored = defaults.dictionary(forKey: preferenceKey) as? [String: Bool] ?? [:]
        stored[series.id] = value
        defaults.set(stored, forKey: preferenceKey)
    }

    /// Plays a complete narration from the moment matching the recording when that recording is loaded.
    @MainActor
    static func play(_ document: NarrationDocument, url: URL, player: AudioPlayerService, narrations: NarrationService = .shared) async {
        let loadedTrack = player.currentTrackId
        let start = await translatedStart(for: document, player: player, narrations: narrations)
        // The listener may have started something else while the timeline loaded.
        guard player.currentTrackId == loadedTrack else { return }
        if let start { narrations.savePosition(documentID: document.id, position: start) }
        player.playNarration(document, url: url)
    }

    /// Reads the recording's position before awaiting, so a track change meanwhile cannot supply it.
    @MainActor
    static func translatedStart(
        for document: NarrationDocument, player: AudioPlayerService, narrations: NarrationService = .shared
    ) async -> TimeInterval? {
        guard !player.isPlayingNarration, player.currentTrackId == document.discourseID, player.currentTime > 0 else { return nil }
        let originalTime = player.currentTime
        let mapped = await narrations.timeline(for: document)?.translatedTime(forOriginal: originalTime)
        guard player.currentTrackId == document.discourseID, !player.isPlayingNarration else { return nil }
        return mapped
    }

    /// The most useful saved rendition in the target language: complete first, then most progress.
    @MainActor
    static func savedNarration(for discourseID: String, target: String, in documents: [NarrationDocument]) -> NarrationDocument? {
        documents
            .filter { $0.discourseID == discourseID && NarrationLanguageSupport.isSameLanguage($0.selection.targetLanguage, target) }
            .max { lhs, rhs in
                if lhs.isComplete != rhs.isComplete { return !lhs.isComplete }
                if lhs.segments.count != rhs.segments.count { return lhs.segments.count < rhs.segments.count }
                return lhs.updatedAt < rhs.updatedAt
            }
    }
}
#endif
