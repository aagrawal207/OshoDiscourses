#if TRANSLATED_NARRATION
import Foundation
import Testing
@testable import OshoDiscourses

@MainActor
@Suite
struct NarrationVoicePreviewTests {
    @Test func previewPausesBeforeSpeakingAndUsesTheRequestedVoiceTextAndPace() throws {
        let speaker = VoicePreviewSpeakerFake()
        let preview = NarrationVoicePreview(speaker: speaker)
        let owner = UUID()
        var didPause = false
        speaker.beforeSpeaking = { #expect(didPause) }

        preview.play(voice: voice("first"), sampleText: "Un passage traduit.", pace: .osho, ownerID: owner) {
            didPause = true
        }

        let request = try #require(speaker.requests.first)
        #expect(request.voiceID == "first")
        #expect(request.text == "Un passage traduit.")
        #expect(request.pace == .osho)
        #expect(preview.activeVoiceID == "first")
        #expect(preview.ownerID == owner)
        #expect(preview.failure == nil)
    }

    @Test func rapidSwitchStopsOldSpeechAndIgnoresItsLateCompletion() {
        let speaker = VoicePreviewSpeakerFake()
        let preview = NarrationVoicePreview(speaker: speaker)
        let owner = UUID()
        play(preview, id: "first", owner: owner)
        play(preview, id: "second", owner: owner)
        play(preview, id: "third", owner: owner)

        #expect(speaker.events == ["stop", "speak:first", "stop", "speak:second", "stop", "speak:third"])
        speaker.requests[0].completion()
        speaker.requests[1].completion()
        #expect(preview.activeVoiceID == "third")
        #expect(preview.ownerID == owner)
        speaker.requests[2].completion()
        #expect(preview.activeVoiceID == nil)
        #expect(preview.ownerID == nil)
    }

    @Test func switchingBackToTheSameVoiceStillRejectsTheOldCompletion() {
        let speaker = VoicePreviewSpeakerFake()
        let preview = NarrationVoicePreview(speaker: speaker)
        let owner = UUID()
        play(preview, id: "first", owner: owner)
        play(preview, id: "second", owner: owner)
        play(preview, id: "first", owner: owner)
        speaker.requests[0].completion()
        #expect(preview.activeVoiceID == "first")
        speaker.requests[2].completion()
        #expect(preview.activeVoiceID == nil)
    }

    @Test func stoppingImmediatelyClearsStateAndLateCallbacksCannotRestartIt() {
        let speaker = VoicePreviewSpeakerFake()
        let preview = NarrationVoicePreview(speaker: speaker)
        let owner = UUID()
        var pauseCount = 0
        preview.play(voice: voice("first"), sampleText: nil, pace: .natural, ownerID: owner) { pauseCount += 1 }
        preview.stop(ownerID: owner)
        speaker.requests[0].completion()
        #expect(preview.activeVoiceID == nil)
        #expect(preview.ownerID == nil)
        #expect(preview.failure == nil)
        #expect(speaker.events.last == "stop")
        #expect(pauseCount == 1)
    }

    @Test func aPreviousChooserCannotStopTheCurrentWindowsPreview() {
        let speaker = VoicePreviewSpeakerFake()
        let preview = NarrationVoicePreview(speaker: speaker)
        let firstOwner = UUID()
        let secondOwner = UUID()
        play(preview, id: "first", owner: firstOwner)
        play(preview, id: "second", owner: secondOwner)
        preview.stop(ownerID: firstOwner)
        #expect(preview.activeVoiceID == "second")
        #expect(preview.ownerID == secondOwner)
        #expect(speaker.events.last == "speak:second")
        preview.stop(ownerID: secondOwner)
        #expect(preview.activeVoiceID == nil)
    }

    @Test func missingVoiceStopsAnyCurrentPreviewAndOffersAnExplicitFailure() {
        let speaker = VoicePreviewSpeakerFake()
        let preview = NarrationVoicePreview(speaker: speaker)
        let owner = UUID()
        play(preview, id: "first", owner: owner)
        speaker.error = NativeNarrationSpeechError.voiceUnavailable
        play(preview, id: "missing", owner: owner)

        #expect(preview.activeVoiceID == nil)
        #expect(preview.ownerID == nil)
        #expect(preview.failure?.ownerID == owner)
        #expect(preview.failure?.voiceID == "missing")
        #expect(preview.failure?.message == NativeNarrationSpeechError.voiceUnavailable.localizedDescription)
        #expect(speaker.events.last == "stop")
        speaker.requests[0].completion()
        #expect(preview.failure != nil)

        speaker.error = nil
        play(preview, id: "available", owner: owner)
        #expect(preview.activeVoiceID == "available")
        #expect(preview.failure == nil)
    }

    @Test func stoppingFailedPreviewClearsItsMessage() {
        let speaker = VoicePreviewSpeakerFake()
        speaker.error = NativeNarrationSpeechError.voiceUnavailable
        let preview = NarrationVoicePreview(speaker: speaker)
        let owner = UUID()
        play(preview, id: "missing", owner: owner)
        preview.stop(ownerID: UUID())
        #expect(preview.failure != nil)
        preview.stop(ownerID: owner)
        #expect(preview.failure == nil)
    }

    @Test func synchronousCompletionDoesNotLeaveAStuckStopButton() {
        let speaker = VoicePreviewSpeakerFake()
        speaker.finishesSynchronously = true
        let preview = NarrationVoicePreview(speaker: speaker)
        play(preview, id: "first", owner: UUID())
        #expect(preview.activeVoiceID == nil)
        #expect(preview.ownerID == nil)
    }

    @Test func nativeBackendRejectsAnUnknownIdentifierWithoutSpeaking() {
        let speaker = NativeNarrationVoicePreviewSpeaker()
        #expect(throws: NativeNarrationSpeechError.voiceUnavailable) {
            try speaker.speak(text: "Bonjour.", voiceID: "com.apple.voice.nonexistent.preview-test", pace: .natural) {
                Issue.record("An unavailable voice must not start speech.")
            }
        }
    }

    @Test func sampleTextTakesPrecedenceAndIsBoundedWithoutSplittingGraphemes() {
        let sample = String(repeating: "é👨‍👩‍👧‍👦", count: 150)
        let result = NarrationVoicePreview.previewText(for: voice("french"), sampleText: " \n\(sample) \n")
        #expect(result == String(sample.prefix(200)))
        #expect(result.count == 200)
    }

    @Test func blankSamplesUseTheVoicesOwnLanguage() {
        let french = NarrationVoicePreview.previewText(for: voice("french"), sampleText: " \n\t")
        let hindi = NarrationVoicePreview.previewText(for: voice("hindi", language: "hi-IN"), sampleText: nil)
        #expect(french.hasPrefix("Prenez"))
        #expect(hindi.hasPrefix("एक"))
        #expect(french.count <= 200)
        #expect(hindi.count <= 200)
    }

    @Test func chineseFallbackMatchesTheTargetScript() {
        let simplified = NarrationVoicePreview.previewText(for: voice("simplified", language: "zh-CN"), sampleText: nil)
        let traditional = NarrationVoicePreview.previewText(for: voice("traditional", language: "zh-TW"), sampleText: nil)
        #expect(simplified.contains("静"))
        #expect(traditional.contains("靜"))
        #expect(simplified != traditional)
    }

    @Test func unknownLanguageUsesTheVoiceNameInsteadOfAnEnglishPassage() {
        let unknown = NarrationVoice(id: "unknown", name: "မင်္ဂလာပါ", language: "my-MM", quality: 1)
        #expect(NarrationVoicePreview.previewText(for: unknown, sampleText: nil) == unknown.name)
    }

    private func play(_ preview: NarrationVoicePreview, id: String, owner: UUID) {
        preview.play(voice: voice(id), sampleText: nil, pace: .natural, ownerID: owner, pausePlayback: {})
    }

    private func voice(_ id: String, language: String = "fr-FR") -> NarrationVoice {
        NarrationVoice(id: id, name: id, language: language, quality: 1)
    }
}

@Suite
struct NarrationVoicePreferencesTests {
    @Test func preferenceIsSharedByRegionsButNotByLanguages() throws {
        try withDefaults { defaults in
            let french = voice("french", "fr-CA")
            NarrationVoicePreferences.setPreferredVoiceID(french.id, for: "fr-FR", defaults: defaults)
            #expect(NarrationVoicePreferences.preferredVoiceID(for: "fr-CA", voices: [french], defaults: defaults) == french.id)
            #expect(NarrationVoicePreferences.preferredVoiceID(for: "de", voices: [french], defaults: defaults) == nil)
        }
    }

    @Test func oppositeScriptsKeepSeparatePreferredVoices() throws {
        try withDefaults { defaults in
            let simplified = voice("simplified", "zh-CN")
            let traditional = voice("traditional", "zh-TW")
            let voices = [simplified, traditional]
            NarrationVoicePreferences.setPreferredVoiceID(simplified.id, for: "zh-Hans", defaults: defaults)
            NarrationVoicePreferences.setPreferredVoiceID(traditional.id, for: "zh-Hant", defaults: defaults)
            #expect(NarrationVoicePreferences.preferredVoiceID(for: "zh-CN", voices: voices, defaults: defaults) == simplified.id)
            #expect(NarrationVoicePreferences.preferredVoiceID(for: "zh-TW", voices: voices, defaults: defaults) == traditional.id)
        }
    }

    @Test func absentOrIncompatibleVoicesNeverBecomeThePreferredChoice() throws {
        try withDefaults { defaults in
            let french = voice("french", "fr-FR")
            let german = voice("german", "de-DE")
            #expect(NarrationVoicePreferences.preferredVoiceID(for: "fr", voices: [french], defaults: defaults) == nil)
            NarrationVoicePreferences.setPreferredVoiceID(french.id, for: "fr", defaults: defaults)
            #expect(NarrationVoicePreferences.preferredVoiceID(for: "fr", voices: [], defaults: defaults) == nil)
            #expect(NarrationVoicePreferences.preferredVoiceID(for: "fr", voices: [german], defaults: defaults) == nil)
            NarrationVoicePreferences.setPreferredVoiceID(german.id, for: "fr", defaults: defaults)
            #expect(NarrationVoicePreferences.preferredVoiceID(for: "fr", voices: [french, german], defaults: defaults) == nil)
        }
    }

    @Test func anIdentifierFromTheWrongScriptIsRejectedEvenWhenInstalled() throws {
        try withDefaults { defaults in
            let traditional = voice("traditional", "zh-TW")
            NarrationVoicePreferences.setPreferredVoiceID(traditional.id, for: "zh-Hans", defaults: defaults)
            #expect(NarrationVoicePreferences.preferredVoiceID(for: "zh-Hans", voices: [traditional], defaults: defaults) == nil)
        }
    }

    @Test func clearingPreferencesDoesNotAffectOtherLanguages() throws {
        try withDefaults { defaults in
            let french = voice("french", "fr-FR")
            let german = voice("german", "de-DE")
            let voices = [french, german]
            NarrationVoicePreferences.setPreferredVoiceID(french.id, for: "fr", defaults: defaults)
            NarrationVoicePreferences.setPreferredVoiceID(german.id, for: "de", defaults: defaults)
            NarrationVoicePreferences.setPreferredVoiceID(nil, for: "fr", defaults: defaults)
            #expect(NarrationVoicePreferences.preferredVoiceID(for: "fr", voices: voices, defaults: defaults) == nil)
            #expect(NarrationVoicePreferences.preferredVoiceID(for: "de", voices: voices, defaults: defaults) == german.id)
            NarrationVoicePreferences.setPreferredVoiceID("", for: "de", defaults: defaults)
            #expect(NarrationVoicePreferences.preferredVoiceID(for: "de", voices: voices, defaults: defaults) == nil)
        }
    }

    @Test func blankLanguageDoesNotCreateAPreference() throws {
        try withDefaults { defaults in
            NarrationVoicePreferences.setPreferredVoiceID("voice", for: " \n", defaults: defaults)
            #expect(NarrationVoicePreferences.preferredVoiceID(for: "", voices: [], defaults: defaults) == nil)
            #expect(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("narration.preferredVoice.") }.isEmpty)
        }
    }

    private func voice(_ id: String, _ language: String) -> NarrationVoice {
        NarrationVoice(id: id, name: id, language: language, quality: 1)
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "NarrationVoicePreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
}

@MainActor
private final class VoicePreviewSpeakerFake: NarrationVoicePreviewSpeaking {
    struct Request {
        let text: String
        let voiceID: String
        let pace: NarrationPace
        let completion: @MainActor @Sendable () -> Void
    }

    var requests: [Request] = []
    var events: [String] = []
    var error: (any Error)?
    var beforeSpeaking: (@MainActor () -> Void)?
    var finishesSynchronously = false

    func speak(
        text: String, voiceID: String, pace: NarrationPace,
        completion: @escaping @MainActor @Sendable () -> Void
    ) throws {
        beforeSpeaking?()
        if let error { throw error }
        events.append("speak:\(voiceID)")
        requests.append(Request(text: text, voiceID: voiceID, pace: pace, completion: completion))
        if finishesSynchronously { completion() }
    }

    func stop() { events.append("stop") }
}
#endif
