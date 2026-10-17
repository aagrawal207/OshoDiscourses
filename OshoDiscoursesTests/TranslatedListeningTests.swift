import Foundation
import Testing
@testable import OshoDiscourses

#if TRANSLATED_NARRATION
@Suite
struct TranslatedListeningTests {
    private let modeKey = "narration.translatedSeries"
    private let targetsKey = "narration.targetLanguageBySeries"
    private let preferredKey = "narration.preferredTargetLanguage"

    @Test func freshPreferencesKeepTheOriginalCounterpartDefault() throws {
        try withDefaults { defaults in
            #expect(TranslatedListening.targetLanguage(for: series(.english), defaults: defaults) == "hi")
            #expect(TranslatedListening.targetLanguage(for: series(.hindi), defaults: defaults) == "en")
            #expect(defaults.object(forKey: modeKey) == nil)
        }
    }

    @Test(arguments: [SeriesInfo.Language.english, .hindi])
    func legacyTranslatedChoiceMigratesWithoutRewritingHistory(_ language: SeriesInfo.Language) throws {
        try withDefaults { defaults in
            let original = series(language)
            let discourseID = "\(original.id)-1"
            defaults.set([original.id: true, "other-series": false], forKey: modeKey)
            defaults.set("fr", forKey: preferredKey)
            defaults.set([discourseID], forKey: "recentlyPlayed")
            defaults.set([discourseID], forKey: "completedDiscourseIDs")
            let expected = language == .english ? "hi" : "en"

            #expect(TranslatedListening.targetLanguage(for: original, defaults: defaults) == expected)
            #expect(TranslatedListening.targetLanguage(for: original, defaults: defaults) == expected)
            #expect(defaults.dictionary(forKey: targetsKey) as? [String: String] == [original.id: expected])
            #expect(defaults.dictionary(forKey: modeKey) as? [String: Bool] == [original.id: true, "other-series": false])
            #expect(defaults.string(forKey: preferredKey) == "fr")
            #expect(defaults.stringArray(forKey: "recentlyPlayed") == [discourseID])
            #expect(defaults.stringArray(forKey: "completedDiscourseIDs") == [discourseID])
            #expect(original.id == "\(language.rawValue)-fixture")
        }
    }

    @Test func legacyOriginalChoiceDoesNotInventATranslationPreference() throws {
        try withDefaults { defaults in
            let original = series(.english)
            defaults.set([original.id: false], forKey: modeKey)
            defaults.set("fr", forKey: preferredKey)

            #expect(TranslatedListening.targetLanguage(for: original, defaults: defaults) == "fr")
            #expect(defaults.object(forKey: targetsKey) == nil)
            #expect(defaults.dictionary(forKey: modeKey) as? [String: Bool] == [original.id: false])
        }
    }

    @available(macCatalyst 26.0, *)
    @Test func rowModeHonorsHiddenLanguageDefaultAndExplicitChoices() throws {
        try withDefaults { defaults in
            let original = try #require(Catalog.allSeries.first {
                $0.language == .english && TranscriptCatalog.transcriptCount(forSeriesID: $0.id) > 0
            })
            #expect(TranslatedListening.prefersTranslation(original, filter: .hindi, defaults: defaults))
            defaults.set([original.id: false], forKey: modeKey)
            #expect(!TranslatedListening.prefersTranslation(original, filter: .hindi, defaults: defaults))
            TranslatedListening.setTargetLanguage("fr", for: original, defaults: defaults)
            #expect(TranslatedListening.prefersTranslation(original, filter: .both, defaults: defaults))
            TranslatedListening.setTargetLanguage("de", for: original, defaults: defaults)
            #expect(TranslatedListening.prefersTranslation(original, filter: .both, defaults: defaults))
        }
    }

    @Test func targetChangesAreRememberedPerSeriesAndAsTheGlobalDefault() throws {
        try withDefaults { defaults in
            let first = series(.english)
            let second = series(.hindi)
            let unseen = series(.english, prefix: "unseen")
            TranslatedListening.setTargetLanguage("fr", for: first, defaults: defaults)
            TranslatedListening.setTargetLanguage("de", for: second, defaults: defaults)

            #expect(TranslatedListening.targetLanguage(for: first, defaults: defaults) == "fr")
            #expect(TranslatedListening.targetLanguage(for: second, defaults: defaults) == "de")
            #expect(TranslatedListening.targetLanguage(for: unseen, defaults: defaults) == "de")
            #expect(defaults.string(forKey: preferredKey) == "de")
            #expect(defaults.dictionary(forKey: modeKey) as? [String: Bool] == [first.id: true, second.id: true])
        }
    }

    @Test func originalModePreservesTheLastTranslationTarget() throws {
        try withDefaults { defaults in
            let original = series(.english)
            TranslatedListening.setTargetLanguage("fr", for: original, defaults: defaults)
            TranslatedListening.setPrefersTranslation(false, for: original, defaults: defaults)
            #expect(TranslatedListening.targetLanguage(for: original, defaults: defaults) == "fr")
            #expect(defaults.dictionary(forKey: modeKey) as? [String: Bool] == [original.id: false])
            #expect(defaults.string(forKey: preferredKey) == "fr")
            TranslatedListening.setPrefersTranslation(true, for: original, defaults: defaults)
            #expect(TranslatedListening.targetLanguage(for: original, defaults: defaults) == "fr")
        }
    }

    @Test func enablingTranslationPinsTheGlobalChoiceWithoutChangingOtherSeries() throws {
        try withDefaults { defaults in
            let first = series(.english)
            defaults.set("fr", forKey: preferredKey)
            TranslatedListening.setPrefersTranslation(true, for: first, defaults: defaults)
            TranslatedListening.setTargetLanguage("de", for: series(.hindi), defaults: defaults)
            #expect(TranslatedListening.targetLanguage(for: first, defaults: defaults) == "fr")
        }
    }

    @Test(arguments: [false, true])
    func sameSourcePreferenceUsesTheOldCounterpart(_ perSeries: Bool) throws {
        try withDefaults { defaults in
            let original = series(.english)
            defaults.set(perSeries ? "fr" : "en-US", forKey: preferredKey)
            if perSeries { defaults.set([original.id: "en-GB"], forKey: targetsKey) }
            #expect(TranslatedListening.targetLanguage(for: original, defaults: defaults) == "hi")
            #expect(TranslatedListening.resolvedTargetLanguage(
                for: original, availableLanguages: ["fr", "hi"], defaults: defaults
            ) == "hi")
        }
    }

    @Test func blankOrSameSourceSelectionsDoNotOverwriteAValidChoice() throws {
        try withDefaults { defaults in
            let original = series(.english)
            TranslatedListening.setTargetLanguage("fr", for: original, defaults: defaults)
            TranslatedListening.setTargetLanguage("en-US", for: original, defaults: defaults)
            TranslatedListening.setTargetLanguage(" \n", for: original, defaults: defaults)
            #expect(TranslatedListening.targetLanguage(for: original, defaults: defaults) == "fr")
            #expect(defaults.string(forKey: preferredKey) == "fr")
        }
    }

    @Test func unavailablePreferenceFallsBackOnlyToAnActualSupportedPair() throws {
        try withDefaults { defaults in
            let original = series(.english)
            TranslatedListening.setTargetLanguage("xx-Unsupported", for: original, defaults: defaults)
            #expect(TranslatedListening.resolvedTargetLanguage(
                for: original, availableLanguages: ["fr", "hi"], defaults: defaults
            ) == "hi")
            #expect(TranslatedListening.resolvedTargetLanguage(
                for: original, availableLanguages: ["en-GB", "fr"], defaults: defaults
            ) == "fr")
            #expect(TranslatedListening.resolvedTargetLanguage(
                for: original, availableLanguages: ["en"], defaults: defaults
            ) == nil)
            #expect(defaults.string(forKey: preferredKey) == "xx-Unsupported")
        }
    }

    @Test func noAvailableLanguagesDoesNotEraseRememberedChoices() throws {
        try withDefaults { defaults in
            let original = series(.english)
            TranslatedListening.setTargetLanguage("fr", for: original, defaults: defaults)
            #expect(TranslatedListening.resolvedTargetLanguage(for: original, availableLanguages: [], defaults: defaults) == nil)
            #expect(TranslatedListening.targetLanguage(for: original, defaults: defaults) == "fr")
            #expect(defaults.dictionary(forKey: modeKey) as? [String: Bool] == [original.id: true])
        }
    }

    @Test func supportedRegionalTagsMatchWithoutMergingDifferentScripts() throws {
        try withDefaults { defaults in
            let original = series(.english)
            TranslatedListening.setTargetLanguage("zh-Hant", for: original, defaults: defaults)
            #expect(TranslatedListening.resolvedTargetLanguage(
                for: original, availableLanguages: ["fr", "zh-Hans", "zh-TW"], defaults: defaults
            ) == "zh-TW")
        }
    }

    @Test @MainActor func changingTargetWhileTranslatedSelectsADifferentSavedVariant() throws {
        try withDefaults { defaults in
            let original = series(.english)
            let french = document(target: "fr")
            let german = document(target: "de")
            let documents = [french, german]
            TranslatedListening.setTargetLanguage("fr", for: original, defaults: defaults)
            #expect(TranslatedListening.savedNarration(
                for: french.discourseID, target: TranslatedListening.targetLanguage(for: original, defaults: defaults), in: documents
            )?.id == french.id)

            TranslatedListening.setTargetLanguage("de", for: original, defaults: defaults)
            #expect(defaults.dictionary(forKey: modeKey) as? [String: Bool] == [original.id: true])
            #expect(TranslatedListening.savedNarration(
                for: german.discourseID, target: TranslatedListening.targetLanguage(for: original, defaults: defaults), in: documents
            )?.id == german.id)
            #expect(documents.map(\.id) == ["saved-fr", "saved-de"])
        }
    }

    @Test @MainActor func savedNarrationLookupPreservesTargetScript() {
        let simplified = document(target: "zh-Hans")
        let traditional = document(target: "zh-Hant")
        #expect(TranslatedListening.savedNarration(
            for: traditional.discourseID, target: "zh-TW", in: [traditional, simplified]
        )?.id == traditional.id)
    }

    /// Opening a discourse lands on audio the listener already has, even if pace or voice preferences changed since.
    @Test @MainActor func anyLanguageLookupPrefersCompleteThenMostProgress() {
        var partial = document(target: "hi", id: "partial")
        partial.segments = []
        partial.audioFileName = nil
        let complete = document(target: "fr", id: "complete")
        var older = document(target: "es", id: "older-partial")
        older.audioFileName = nil
        #expect(TranslatedListening.savedNarration(for: complete.discourseID, in: [partial, complete, older])?.id == "complete")
        #expect(TranslatedListening.savedNarration(for: complete.discourseID, in: [partial, older])?.id == "older-partial")
        #expect(TranslatedListening.savedNarration(for: "another-discourse", in: [complete]) == nil)
    }

    /// A saved version matches a choice by language/script, voice and pace, not by display names.
    @Test func sameVersionIgnoresDisplayNamesButNotPaceVoiceOrScript() {
        let voice = NarrationVoice(id: "lekha", name: "Lekha", language: "hi-IN", quality: 1)
        let saved = NarrationSelection(sourceLanguage: "en", targetLanguage: "hi", voice: voice, pace: .natural)
        let renamed = NarrationVoice(id: "lekha", name: "Lekha (Enhanced name)", language: "hi-IN", quality: 2)
        #expect(TranslatedListening.isSameVersion(saved, .init(sourceLanguage: "en", targetLanguage: "hi-IN", voice: renamed, pace: .natural)))
        #expect(!TranslatedListening.isSameVersion(saved, .init(sourceLanguage: "en", targetLanguage: "hi", voice: voice, pace: .osho)))
        let other = NarrationVoice(id: "kiyara", name: "Lekha", language: "hi-IN", quality: 1)
        #expect(!TranslatedListening.isSameVersion(saved, .init(sourceLanguage: "en", targetLanguage: "hi", voice: other, pace: .natural)))
        let simplified = NarrationSelection(sourceLanguage: "en", targetLanguage: "zh-Hans", voice: voice)
        #expect(!TranslatedListening.isSameVersion(simplified, .init(sourceLanguage: "en", targetLanguage: "zh-Hant", voice: voice)))
    }

    private func series(_ language: SeriesInfo.Language, prefix: String = "fixture") -> SeriesInfo {
        SeriesInfo(name: "Fixture", filePrefix: prefix, count: 1, language: language, urlType: .underscore)
    }

    private func document(target: String, id: String? = nil) -> NarrationDocument {
        NarrationDocument(
            id: id ?? "saved-\(target)", discourseID: "english-fixture-1", sourceDigest: "source",
            selection: NarrationSelection(
                sourceLanguage: "en", targetLanguage: target,
                voice: NarrationVoice(id: target, name: "Fixture", language: target, quality: 1)
            ),
            expectedSegmentCount: 1,
            segments: [NarrationSegment(index: 0, sourceParagraphIndex: 0, text: "Translation",
                                        audioFileName: "0.m4a", duration: 10)],
            audioFileName: "narration.m4a", duration: 10, updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "TranslatedListeningTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
}
#endif
