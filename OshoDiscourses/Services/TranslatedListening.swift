#if TRANSLATED_NARRATION
import Foundation

/// Language preferences are separate from recording history and saved narration identities.
enum TranslatedListening {
    private static let preferenceKey = "narration.translatedSeries"
    private static let targetPreferenceKey = "narration.targetLanguageBySeries"
    private static let lastTargetPreferenceKey = "narration.preferredTargetLanguage"

    static func targetLanguage(for series: SeriesInfo) -> String {
        targetLanguage(for: series, defaults: .standard)
    }

    /// Pair availability is checked asynchronously by the selector, not inferred from a stored tag.
    static func targetLanguage(for series: SeriesInfo, defaults: UserDefaults) -> String {
        var targets = defaults.dictionary(forKey: targetPreferenceKey) as? [String: String] ?? [:]
        if targets[series.id] == nil,
           (defaults.dictionary(forKey: preferenceKey) as? [String: Bool])?[series.id] == true {
            // A legacy translated series meant its counterpart, regardless of later global choices.
            targets[series.id] = counterpart(for: series)
            defaults.set(targets, forKey: targetPreferenceKey)
        }
        let preferred = targets[series.id] ?? defaults.string(forKey: lastTargetPreferenceKey)
        guard let preferred, !preferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !NarrationLanguageSupport.isSameLanguage(preferred, NarrationLanguageSupport.sourceLanguage(for: series.language))
        else { return counterpart(for: series) }
        return preferred
    }

    static func setTargetLanguage(_ language: String, for series: SeriesInfo, defaults: UserDefaults = .standard) {
        guard !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !NarrationLanguageSupport.isSameLanguage(language, NarrationLanguageSupport.sourceLanguage(for: series.language))
        else { return }
        var targets = defaults.dictionary(forKey: targetPreferenceKey) as? [String: String] ?? [:]
        targets[series.id] = language
        defaults.set(targets, forKey: targetPreferenceKey)
        defaults.set(language, forKey: lastTargetPreferenceKey)
        setPrefersTranslation(true, for: series, defaults: defaults)
    }

    /// A temporarily unsupported preference is retained for devices or OS versions that support it.
    static func resolvedTargetLanguage(
        for series: SeriesInfo, availableLanguages: [String], defaults: UserDefaults = .standard
    ) -> String? {
        let source = NarrationLanguageSupport.sourceLanguage(for: series.language)
        let targets = availableLanguages.filter { !NarrationLanguageSupport.isSameLanguage($0, source) }
        for preferred in [targetLanguage(for: series, defaults: defaults), counterpart(for: series)] {
            if let match = targets.first(where: {
                NarrationLanguageSupport.languageAndScript(for: $0) == NarrationLanguageSupport.languageAndScript(for: preferred)
            }) { return match }
        }
        return targets.first
    }

    private static func counterpart(for series: SeriesInfo) -> String {
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
        if value {
            let target = targetLanguage(for: series, defaults: defaults)
            var targets = defaults.dictionary(forKey: targetPreferenceKey) as? [String: String] ?? [:]
            targets[series.id] = target
            defaults.set(targets, forKey: targetPreferenceKey)
        }
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
        savedNarration(for: discourseID, in: documents.filter {
            NarrationLanguageSupport.languageAndScript(for: $0.selection.targetLanguage)
                == NarrationLanguageSupport.languageAndScript(for: target)
        })
    }

    /// The most useful saved rendition in any language.
    @MainActor
    static func savedNarration(for discourseID: String, in documents: [NarrationDocument]) -> NarrationDocument? {
        documents.filter { $0.discourseID == discourseID }.max { lhs, rhs in
            if lhs.isComplete != rhs.isComplete { return !lhs.isComplete }
            if lhs.segments.count != rhs.segments.count { return lhs.segments.count < rhs.segments.count }
            return lhs.updatedAt < rhs.updatedAt
        }
    }

    /// Same language, voice and pace; voice display names and quality labels change between OS versions.
    static func isSameVersion(_ lhs: NarrationSelection, _ rhs: NarrationSelection) -> Bool {
        NarrationLanguageSupport.languageAndScript(for: lhs.targetLanguage)
            == NarrationLanguageSupport.languageAndScript(for: rhs.targetLanguage)
            && lhs.voice.id == rhs.voice.id && lhs.pace == rhs.pace
    }
}
#endif
