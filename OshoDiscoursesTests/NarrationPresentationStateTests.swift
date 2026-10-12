#if TRANSLATED_NARRATION
import Foundation
import SwiftUI
import Testing
import Translation
@testable import OshoDiscourses

@Suite
struct NarrationPresentationStateTests {
    @available(macCatalyst 26.0, *)
    @Test func latestCompatibleSavedChoiceKeepsItsExactVoice() {
        let french = voice("french", "fr-FR")
        let preferredFrench = voice("preferred-french", "fr-CA")
        let spanish = voice("spanish", "es-ES")
        let saved = [
            document(id: "older", target: "es", voice: spanish, updated: 1),
            document(id: "preferred", target: "fr", voice: preferredFrench, updated: 2),
            document(id: "missing-voice", target: "es", voice: voice("removed", "es-ES"), updated: 3),
            document(id: "unsupported-pair", target: "de", voice: voice("german", "de-DE"), updated: 4),
        ]
        let choice = NarrationSelectionPresentation.choice(
            sourceLanguage: "en", languages: [option("fr", [french, preferredFrench]), option("es", [spanish])],
            languageID: "", voiceID: "", saved: saved
        )
        #expect(choice.languageID == "fr")
        #expect(choice.voiceID == "preferred-french")
    }

    @available(macCatalyst 26.0, *)
    @Test func checkingAgainPreservesTheListenersCurrentChoice() {
        let french = voice("french", "fr-FR")
        let spanish = voice("spanish", "es-ES")
        let selectedSpanish = voice("selected-spanish", "es-MX")
        let choice = NarrationSelectionPresentation.choice(
            sourceLanguage: "en", languages: [option("fr", [french]), option("es", [spanish, selectedSpanish])],
            languageID: "es", voiceID: selectedSpanish.id,
            saved: [document(id: "newest", target: "fr", voice: french)]
        )
        #expect(choice.languageID == "es")
        #expect(choice.voiceID == "selected-spanish")
    }

    @available(macCatalyst 26.0, *)
    @Test func openingASpecificLibraryVariantTakesPrecedenceOverRecency() {
        let french = voice("french", "fr-FR")
        let spanish = voice("spanish", "es-ES")
        let choice = NarrationSelectionPresentation.choice(
            sourceLanguage: "en", languages: [option("fr", [french]), option("es", [spanish])],
            languageID: "", voiceID: "", saved: [
                document(id: "selected", target: "fr", voice: french, updated: 1),
                document(id: "latest", target: "es", voice: spanish, updated: 2),
            ], preferredDocumentID: "selected"
        )
        #expect(choice.languageID == "fr")
        #expect(choice.voiceID == "french")
    }

    @available(macCatalyst 26.0, *)
    @Test func savedRegionalLanguageUsesTheSupportedPickerIdentifier() {
        let english = voice("english", "en-GB")
        let choice = NarrationSelectionPresentation.choice(
            sourceLanguage: "hi", languages: [option("en", [english])], languageID: "", voiceID: "",
            saved: [document(source: "hi", target: "en-US", voice: english)]
        )
        #expect(choice.languageID == "en")
        #expect(choice.voiceID == "english")
    }

    @available(macCatalyst 26.0, *)
    @Test func savedVoicesDoNotEstablishTranslationOrScriptSupport() {
        let simplified = voice("simplified", "zh-CN")
        let french = voice("french", "fr-FR")
        let saved = [document(target: "zh-Hans", voice: simplified), document(id: "french", target: "fr", voice: french)]
        let unavailable = NarrationSelectionPresentation.choice(
            sourceLanguage: "en", languages: [], languageID: "", voiceID: "", saved: saved
        )
        #expect(unavailable.languageID.isEmpty)
        #expect(unavailable.voiceID.isEmpty)
        let incompatible = NarrationSelectionPresentation.choice(
            sourceLanguage: "en", languages: [
                option("zh-Hant", [voice("traditional", "zh-TW")]),
                option("fr", [french], status: .unsupported),
            ], languageID: "", voiceID: "", saved: saved
        )
        #expect(incompatible.languageID.isEmpty)
        #expect(incompatible.voiceID.isEmpty)
    }

    @available(macCatalyst 26.0, *)
    @Test func aChosenLanguageWithoutAVoiceStaysVisibleForRecovery() {
        let spanish = voice("spanish", "es-ES")
        let choice = NarrationSelectionPresentation.choice(
            sourceLanguage: "en", languages: [option("fr", []), option("es", [spanish])],
            languageID: "fr", voiceID: "removed-voice", saved: [document(target: "es", voice: spanish)]
        )
        #expect(choice.languageID == "fr")
        #expect(choice.voiceID.isEmpty)
    }

    @available(macCatalyst 26.0, *)
    @Test func theSourceLanguageIsNeverOfferedAsATranslation() {
        let english = voice("english", "en-US")
        let choice = NarrationSelectionPresentation.choice(
            sourceLanguage: "en", languages: [option("en-GB", [english])],
            languageID: "en-GB", voiceID: english.id, saved: [document(target: "en-GB", voice: english)]
        )
        #expect(choice.languageID.isEmpty)
        #expect(choice.voiceID.isEmpty)
    }

    @Test func matchingPausedRenditionResumesWithoutReloading() {
        let reading = document()
        #expect(NarrationPlaybackPresentation.action(for: reading, current: reading, isPlaying: false, hasFailure: false) == .resume)
        #expect(NarrationPlaybackPresentation.action(for: reading, current: reading, isPlaying: true, hasFailure: false) == .readAlong)
    }

    @Test func failedDifferentAndRebuiltRenditionsReload() {
        let reading = document()
        #expect(NarrationPlaybackPresentation.action(for: reading, current: reading, isPlaying: false, hasFailure: true) == .load)
        #expect(NarrationPlaybackPresentation.action(for: reading, current: nil, isPlaying: false, hasFailure: false) == .load)
        #expect(NarrationPlaybackPresentation.action(for: reading, current: document(id: "other"), isPlaying: true, hasFailure: false) == .load)
        #expect(NarrationPlaybackPresentation.action(for: reading, current: document(updated: 2), isPlaying: true, hasFailure: false) == .load)
    }

    @Test(arguments: [CGFloat(0), 10, 24])
    func tappingAPassageOrMovingSlightlyKeepsFollowing(_ movement: CGFloat) {
        var following = NarrationPlaybackPresentation.Following()
        following.scrollPhaseChanged(from: .idle, to: .interacting, offset: 100)
        following.scrollPhaseChanged(from: .interacting, to: .idle, offset: 100 + movement)
        #expect(following.isFollowing)
    }

    @Test func draggingAwayStopsFollowingAndProgrammaticReturnDoesNotStopItAgain() {
        var following = NarrationPlaybackPresentation.Following()
        following.scrollPhaseChanged(from: .idle, to: .interacting, offset: 100)
        following.scrollPhaseChanged(from: .interacting, to: .idle, offset: 125)
        #expect(!following.isFollowing)
        following.isFollowing = true
        following.scrollPhaseChanged(from: .idle, to: .animating, offset: 125)
        following.scrollPhaseChanged(from: .animating, to: .idle, offset: 800)
        #expect(following.isFollowing)
    }

    @Test func flingingHandsControlToTheReaderUntilTheyChooseToFollow() {
        var following = NarrationPlaybackPresentation.Following()
        following.scrollPhaseChanged(from: .idle, to: .interacting, offset: 100)
        following.scrollPhaseChanged(from: .interacting, to: .decelerating, offset: 180)
        following.scrollPhaseChanged(from: .decelerating, to: .idle, offset: 300)
        #expect(!following.isFollowing)
        following.scrollPhaseChanged(from: .idle, to: .interacting, offset: 300)
        following.scrollPhaseChanged(from: .interacting, to: .idle, offset: 300)
        #expect(!following.isFollowing)
    }

    @Test func onlyTheVisiblePlayingRenditionKeepsTheReaderAwake() {
        let reading = document()
        #expect(NarrationPlaybackPresentation.keepsScreenAwake(
            isVisible: true, scenePhase: .active, isPreparing: false, reading: reading, current: reading, isPlaying: true
        ))
        #expect(!NarrationPlaybackPresentation.keepsScreenAwake(
            isVisible: true, scenePhase: .active, isPreparing: false, reading: reading, current: reading, isPlaying: false
        ))
        #expect(!NarrationPlaybackPresentation.keepsScreenAwake(
            isVisible: true, scenePhase: .active, isPreparing: false, reading: nil, current: reading, isPlaying: true
        ))
        #expect(!NarrationPlaybackPresentation.keepsScreenAwake(
            isVisible: false, scenePhase: .active, isPreparing: false, reading: reading, current: reading, isPlaying: true
        ))
    }

    @Test func previewingAnotherOrRebuiltVariantDoesNotHoldTheIdleTimer() {
        let reading = document()
        #expect(!NarrationPlaybackPresentation.keepsScreenAwake(
            isVisible: true, scenePhase: .active, isPreparing: false, reading: reading, current: document(id: "other"), isPlaying: true
        ))
        #expect(!NarrationPlaybackPresentation.keepsScreenAwake(
            isVisible: true, scenePhase: .active, isPreparing: false, reading: reading, current: document(updated: 2), isPlaying: true
        ))
    }

    @Test(arguments: [ScenePhase.inactive, .background])
    func leavingTheActiveSceneReleasesBothReadingAndPreparation(_ phase: ScenePhase) {
        let reading = document()
        #expect(!NarrationPlaybackPresentation.keepsScreenAwake(
            isVisible: true, scenePhase: phase, isPreparing: false, reading: reading, current: reading, isPlaying: true
        ))
        #expect(!NarrationPlaybackPresentation.keepsScreenAwake(
            isVisible: true, scenePhase: phase, isPreparing: true, reading: nil, current: nil, isPlaying: false
        ))
    }

    @Test func foregroundPreparationKeepsItsScreenAwakeUntilDismissal() {
        #expect(NarrationPlaybackPresentation.keepsScreenAwake(
            isVisible: true, scenePhase: .active, isPreparing: true, reading: nil, current: nil, isPlaying: false
        ))
        #expect(!NarrationPlaybackPresentation.keepsScreenAwake(
            isVisible: false, scenePhase: .active, isPreparing: true, reading: nil, current: nil, isPlaying: false
        ))
    }

    @available(macCatalyst 26.0, *)
    private func option(_ id: String, _ voices: [NarrationVoice], status: LanguageAvailability.Status = .supported) -> NarrationLanguageOption {
        NarrationLanguageOption(id: id, support: NarrationTranslationSupport(strategy: .standard, status: status), voices: voices)
    }

    private func voice(_ id: String, _ language: String) -> NarrationVoice {
        NarrationVoice(id: id, name: id, language: language, quality: 1)
    }

    private func document(
        id: String = "variant", source: String = "en", target: String = "fr", voice: NarrationVoice? = nil, updated: TimeInterval = 1
    ) -> NarrationDocument {
        NarrationDocument(
            id: id, discourseID: "fixture-discourse", sourceDigest: "fixture-source",
            selection: NarrationSelection(
                sourceLanguage: source, targetLanguage: target,
                voice: voice ?? NarrationVoice(id: "french", name: "French", language: "fr-FR", quality: 1)
            ), expectedSegmentCount: 1,
            segments: [NarrationSegment(index: 0, sourceParagraphIndex: 0, text: "Translated passage", audioFileName: "0.m4a", duration: 12)],
            audioFileName: "narration.m4a", duration: 12, updatedAt: Date(timeIntervalSince1970: updated)
        )
    }
}
#endif
