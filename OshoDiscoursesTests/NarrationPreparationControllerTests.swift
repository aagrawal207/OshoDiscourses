#if TRANSLATED_NARRATION
import Foundation
import SwiftUI
import Testing
import Translation
@testable import OshoDiscourses

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NarrationPreparationControllerTests {
    /// Automatic continues only restart discourses the catalog still offers.
    private let catalogDiscourse = "english-A_Bird_on_the_Wing__-1"
    private let otherCatalogDiscourse = "english-A_Bird_on_the_Wing__-2"

    @available(macCatalyst 26.0, *)
    @Test func startupReservesOneOwnerBeforeAwaitingAndRejectsCompetingStarts() async throws {
        try await withFixture { fixture in
            let gate = PreparationControllerGate()
            fixture.inputs.supportGate = gate
            fixture.start("first")
            let attempt = try #require(fixture.controller.lifetime)
            let owner = try #require(fixture.narrations.preparationOwner)
            let competitor = fixture.makeController()
            defer { competitor.pause() }

            fixture.start("replacement", hostID: UUID())
            competitor.start(
                discourseID: "other-window", selection: fixture.selection, hostID: UUID(),
                player: fixture.player, listen: false
            )
            try await eventually("the first support check") { fixture.inputs.supportCalls.count == 1 }
            #expect(fixture.controller.lifetime?.id == attempt.id)
            #expect(fixture.controller.discourseID == "first")
            #expect(fixture.controller.hostID == fixture.hostID)
            #expect(fixture.controller.stage == .checkingSupport)
            #expect(fixture.narrations.preparationOwner == owner)
            #expect(!competitor.isRunning)
            #expect(competitor.job == nil)
            #expect(fixture.inputs.fetchCalls.isEmpty)

            gate.open()
            let job = try await readyJob(fixture)
            #expect(job.owner == owner)
            #expect(job.id == attempt.id)
            #expect(job.hostID == fixture.hostID)
            #expect(job.transcript.discourseID == "first")
            #expect(job.selection == fixture.selection)
            #expect(fixture.controller.stage == .preparingLanguages)
            #expect(fixture.inputs.supportCalls.first?.source == "en")
            #expect(fixture.inputs.supportCalls.first?.target == "fr")
            #expect(fixture.inputs.fetchCalls == ["first"])
        }
    }

    @available(macCatalyst 26.0, *)
    @Test func explicitPauseInvalidatesTheAttemptAndFreesItsLeaseIdempotently() async throws {
        try await withFixture { fixture in
            fixture.start()
            let job = try await readyJob(fixture)
            fixture.controller.pause()

            #expect(!job.lifetime.isActive)
            #expect(!fixture.controller.isRunning)
            #expect(fixture.controller.job == nil)
            #expect(fixture.controller.errorMessage == nil)
            #expect(fixture.controller.statusMessage == "Preparation paused. Your finished audio is saved.")
            #expect(fixture.narrations.preparationOwner == nil)
            #expect(!fixture.narrations.isPreparing)
            #expect(fixture.narrations.documents.isEmpty)

            let nextOwner = UUID()
            #expect(fixture.narrations.reservePreparation(owner: nextOwner))
            fixture.controller.pause()
            #expect(fixture.narrations.preparationOwner == nextOwner)
            fixture.narrations.releasePreparation(owner: nextOwner)
        }
    }

    @available(macCatalyst 26.0, *)
    @Test func closingAnUnrelatedRootDoesNothingButClosingTheOwningRootPauses() async throws {
        try await withFixture { fixture in
            fixture.start()
            let job = try await readyJob(fixture)
            fixture.controller.hostDisappeared(UUID())
            #expect(fixture.controller.job?.id == job.id)
            #expect(fixture.narrations.preparationOwner == job.owner)
            #expect(job.lifetime.isActive)
            #expect(fixture.controller.statusMessage == nil)

            fixture.controller.hostDisappeared(fixture.hostID)
            #expect(!fixture.controller.isRunning)
            #expect(fixture.controller.job == nil)
            #expect(!job.lifetime.isActive)
            #expect(fixture.narrations.preparationOwner == nil)
            #expect(fixture.controller.statusMessage == "Preparation paused because its window closed. Your finished audio is saved.")
        }
    }

    @available(macCatalyst 26.0, *)
    @Test func cancellingThePresentingTaskDoesNotCancelWindowOwnedPreparation() async throws {
        try await withFixture { fixture in
            let gate = PreparationControllerGate()
            fixture.inputs.supportGate = gate
            let presentation = Task { @MainActor in
                fixture.start()
                try? await Task.sleep(for: .seconds(60))
            }
            defer { presentation.cancel() }
            try await eventually("presentation starts preflight") { fixture.inputs.supportCalls.count == 1 }
            let attempt = try #require(fixture.controller.lifetime)
            let owner = fixture.narrations.preparationOwner

            presentation.cancel()
            await presentation.value
            #expect(fixture.controller.isRunning)
            #expect(attempt.isActive)
            #expect(fixture.narrations.preparationOwner == owner)
            #expect(fixture.controller.statusMessage == nil)

            gate.open()
            let job = try await readyJob(fixture)
            #expect(job.id == attempt.id)
            #expect(job.owner == owner)
            #expect(fixture.controller.errorMessage == nil)
        }
    }

    @available(macCatalyst 26.0, *)
    @Test(arguments: [false, true])
    func delayedOldFetchAndStaleCallbacksCannotStopARestartedAttempt(fetchFails: Bool) async throws {
        try await withFixture { fixture in
            let oldFetch = PreparationControllerGate()
            fixture.inputs.fetchGates["first"] = oldFetch
            if fetchFails { fixture.inputs.fetchErrors["first"] = PreparationControllerTestError.fetch }
            fixture.start("first")
            try await eventually("the first fetch to suspend") { fixture.inputs.fetchCalls == ["first"] }
            let oldAttempt = try #require(fixture.controller.lifetime)
            fixture.controller.pause()
            fixture.start("second")
            let current = try await readyJob(fixture)
            #expect(current.id != oldAttempt.id)

            fixture.controller.updateStage(.creatingAudio, attempt: oldAttempt)
            fixture.controller.finish(.failure(CancellationError()), attempt: oldAttempt)
            fixture.controller.finish(.failure(PreparationControllerTestError.fetch), attempt: oldAttempt)
            fixture.controller.finish(.success(fixture.document(for: "first")), attempt: oldAttempt)
            oldFetch.open()
            try await eventually("the retired fetch to return") { fixture.inputs.completedFetches.contains("first") }

            #expect(!oldAttempt.isActive)
            #expect(current.lifetime.isActive)
            #expect(fixture.controller.job?.id == current.id)
            #expect(fixture.controller.discourseID == "second")
            #expect(fixture.controller.stage == .preparingLanguages)
            #expect(fixture.controller.statusMessage == nil)
            #expect(fixture.controller.errorMessage == nil)
            #expect(fixture.narrations.preparationOwner == current.owner)
            #expect(fixture.inputs.fetchCalls == ["first", "second"])
        }
    }

    @available(macCatalyst 26.0, *)
    @Test func failedFetchSurfacesAnActionableErrorReleasesOwnershipAndCanRetry() async throws {
        try await withFixture { fixture in
            fixture.inputs.fetchErrors["source"] = NSError(
                domain: "test-fetch", code: 1, userInfo: [NSLocalizedDescriptionKey: "private server payload"]
            )
            fixture.start()
            let attempt = try #require(fixture.controller.lifetime)
            try await eventually("fetch failure to retire preparation") { !fixture.controller.isRunning }

            #expect(fixture.controller.stage == .fetchingTranscript)
            #expect(fixture.controller.errorMessage == "Couldn't load the transcript. Check your connection and try again.")
            #expect(fixture.controller.statusMessage == nil)
            #expect(fixture.controller.job == nil)
            #expect(!attempt.isActive)
            #expect(fixture.narrations.preparationOwner == nil)
            #expect(fixture.narrations.documents.isEmpty)

            fixture.inputs.fetchErrors.removeValue(forKey: "source")
            fixture.start()
            let retried = try await readyJob(fixture)
            #expect(retried.id != attempt.id)
            #expect(fixture.controller.errorMessage == nil)
            #expect(fixture.controller.statusMessage == nil)
            #expect(fixture.narrations.preparationOwner == retried.owner)
        }
    }

    @available(macCatalyst 26.0, *)
    @Test func unsupportedLanguageFailsBeforeFetchingAndReleasesOwnership() async throws {
        try await withFixture { fixture in
            fixture.inputs.support = nil
            fixture.start()
            let attempt = try #require(fixture.controller.lifetime)
            try await eventually("unsupported language to finish") { !fixture.controller.isRunning }
            #expect(fixture.controller.errorMessage == NarrationTranslationError.unsupportedPair.localizedDescription)
            #expect(fixture.controller.job == nil)
            #expect(fixture.inputs.fetchCalls.isEmpty)
            #expect(!attempt.isActive)
            #expect(fixture.narrations.preparationOwner == nil)
        }
    }

    @available(macCatalyst 26.0, *)
    @Test func backgroundWithoutPermissionPausesOnlyTheOwningHost() async throws {
        try await withFixture { fixture in
            fixture.start()
            let job = try await readyJob(fixture)
            #expect(!fixture.narrations.continuesInBackground)

            fixture.controller.sceneChanged(.background, hostID: UUID())
            fixture.controller.sceneChanged(.inactive, hostID: fixture.hostID)
            fixture.controller.sceneChanged(.active, hostID: fixture.hostID)
            #expect(fixture.controller.job?.id == job.id)
            #expect(fixture.narrations.preparationOwner == job.owner)

            fixture.controller.sceneChanged(.background, hostID: fixture.hostID)
            #expect(!fixture.controller.isRunning)
            #expect(!job.lifetime.isActive)
            #expect(fixture.controller.job == nil)
            #expect(fixture.narrations.preparationOwner == nil)
            #expect(fixture.controller.errorMessage == nil)
            #expect(fixture.narrations.backgroundStatus == .paused(.notGranted))
            #expect(fixture.controller.statusMessage == fixture.narrations.backgroundStatusMessage)
        }
    }

    @available(macCatalyst 26.0, *)
    @Test func backgroundDuringPreflightReleasesTheLeaseBeforeFetchCanStart() async throws {
        try await withFixture { fixture in
            let gate = PreparationControllerGate()
            fixture.inputs.supportGate = gate
            fixture.start()
            try await eventually("support preflight to suspend") { fixture.inputs.supportCalls.count == 1 }
            let attempt = try #require(fixture.controller.lifetime)
            fixture.controller.sceneChanged(.background, hostID: fixture.hostID)
            #expect(!attempt.isActive)
            #expect(fixture.narrations.preparationOwner == nil)

            gate.open()
            try await eventually("cancelled preflight to return") { fixture.inputs.completedSupportCalls == 1 }
            #expect(fixture.inputs.fetchCalls.isEmpty)
            #expect(fixture.controller.job == nil)
            #expect(!fixture.controller.isRunning)
            #expect(fixture.controller.errorMessage == nil)
        }
    }

    @available(macCatalyst 26.0, *)
    @Test func losingTheServiceLeaseDoesNotReleaseAReplacementOwnersLease() async throws {
        try await withFixture { fixture in
            fixture.start()
            let job = try await readyJob(fixture)
            fixture.narrations.releasePreparation(owner: job.owner)
            let replacement = UUID()
            #expect(fixture.narrations.reservePreparation(owner: replacement))

            fixture.controller.checkServiceOwner()
            #expect(!fixture.controller.isRunning)
            #expect(!job.lifetime.isActive)
            #expect(fixture.controller.job == nil)
            #expect(fixture.narrations.preparationOwner == replacement)
            fixture.narrations.releasePreparation(owner: replacement)
        }
    }

    @available(macCatalyst 26.0, *)
    @Test func finishingTheCurrentAttemptClearsTheJobAndReleasesOwnership() async throws {
        try await withFixture { fixture in
            fixture.start()
            let job = try await readyJob(fixture)
            fixture.controller.updateStage(.creatingAudio, attempt: job.lifetime)
            #expect(fixture.controller.stage == .creatingAudio)
            fixture.controller.finish(.success(fixture.document(for: "source")), attempt: job.lifetime)

            #expect(!fixture.controller.isRunning)
            #expect(!job.lifetime.isActive)
            #expect(fixture.controller.job == nil)
            #expect(fixture.narrations.preparationOwner == nil)
            #expect(fixture.controller.statusMessage == "Ready to listen.")
            #expect(fixture.controller.errorMessage == nil)
            #expect(fixture.player.currentTrackId == nil)
            #expect(!fixture.player.isPlaying)
        }
    }

    @available(macCatalyst 26.0, *)
    @Test func listenerPauseIsRememberedAsPaused() async throws {
        try await withFixture { fixture in
            fixture.start()
            _ = try await readyJob(fixture)
            fixture.controller.pause()
            #expect(fixture.controller.unfinished?.reason == .paused)
            #expect(fixture.controller.stopExplanation(discourseID: "source", selection: fixture.selection)?.reason == .paused)
        }
    }

    @available(macCatalyst 26.0, *)
    /// Only a tap continues: iOS suspends continued-processing work that wasn't started by the listener.
    @Test func leavingTheAppRecordsWhyItStoppedAndWaitsForATap() async throws {
        try await withFixture { fixture in
            fixture.start()
            _ = try await readyJob(fixture)
            fixture.controller.sceneChanged(.background, hostID: fixture.hostID)
            fixture.controller.sceneChanged(.active, hostID: fixture.hostID)
            #expect(!fixture.controller.isRunning)
            #expect(fixture.controller.unfinished?.reason == .leftApp)
            #expect(fixture.controller.stopExplanation(discourseID: "source", selection: fixture.selection)?.reason == .leftApp)

            fixture.start()
            #expect(fixture.controller.isRunning)
            #expect(fixture.controller.unfinished?.reason == nil)
            #expect(fixture.controller.stopExplanation(discourseID: "source", selection: fixture.selection) == nil)
        }
    }

    @available(macCatalyst 26.0, *)
    @Test func aStopByIOSContinuesWhenTheAppIsBack() async throws {
        try await withFixture { fixture in
            fixture.start(catalogDiscourse)
            _ = try await readyJob(fixture)
            fixture.controller.sceneChanged(.background, hostID: fixture.hostID)
            #expect(fixture.controller.unfinished?.reason == .leftApp)

            await fixture.controller.continueInterruptedRun(hostID: fixture.hostID, player: fixture.player)
            #expect(fixture.controller.isRunning)
            #expect(fixture.controller.discourseID == catalogDiscourse)
            #expect(fixture.controller.selection == fixture.selection)
            #expect(fixture.controller.unfinished?.reason == nil)
            #expect(fixture.controller.unfinished?.automaticAttempts == 1)
        }
    }

    /// A run frozen in the background can fail after the app returns; the next check continues it.
    @available(macCatalyst 26.0, *)
    @Test func aFailureAfterReturningIsContinuedAutomatically() async throws {
        try await withFixture { fixture in
            fixture.inputs.fetchErrors[catalogDiscourse] = PreparationControllerTestError.fetch
            fixture.start(catalogDiscourse)
            try await eventually("the failed fetch to stop the run") { !fixture.controller.isRunning }
            #expect(fixture.controller.unfinished?.reason == .failed)

            fixture.inputs.fetchErrors.removeValue(forKey: catalogDiscourse)
            await fixture.controller.continueInterruptedRun(hostID: fixture.hostID, player: fixture.player)
            #expect(fixture.controller.isRunning)
            _ = try await readyJob(fixture)
            #expect(fixture.controller.unfinished?.automaticAttempts == 1)
        }
    }

    @available(macCatalyst 26.0, *)
    @Test func aListenerPauseIsNotContinuedAutomatically() async throws {
        try await withFixture { fixture in
            fixture.start(catalogDiscourse)
            _ = try await readyJob(fixture)
            fixture.controller.pause()
            await fixture.controller.continueInterruptedRun(hostID: fixture.hostID, player: fixture.player)
            #expect(!fixture.controller.isRunning)
            #expect(fixture.controller.unfinished?.reason == .paused)
        }
    }

    @available(macCatalyst 26.0, *)
    @Test func automaticContinuesStopAfterTheLimitWhenNothingNewIsSaved() async throws {
        try await withFixture { fixture in
            fixture.start(catalogDiscourse)
            _ = try await readyJob(fixture)
            fixture.controller.sceneChanged(.background, hostID: fixture.hostID)
            for attempt in 1...NarrationPreparationController.automaticAttemptLimit {
                await fixture.controller.continueInterruptedRun(hostID: fixture.hostID, player: fixture.player)
                #expect(fixture.controller.isRunning, "automatic attempt \(attempt)")
                #expect(fixture.controller.unfinished?.automaticAttempts == attempt)
                _ = try await readyJob(fixture)
                fixture.controller.sceneChanged(.background, hostID: fixture.hostID)
            }
            await fixture.controller.continueInterruptedRun(hostID: fixture.hostID, player: fixture.player)
            #expect(!fixture.controller.isRunning)
            #expect(fixture.controller.unfinished?.reason == .leftApp)
        }
    }

    @available(macCatalyst 26.0, *)
    @Test func aRunForADiscourseNoLongerInTheCatalogIsForgottenNotContinued() async throws {
        try await withFixture { fixture in
            fixture.start("removed-from-catalog")
            _ = try await readyJob(fixture)
            fixture.controller.sceneChanged(.background, hostID: fixture.hostID)
            await fixture.controller.continueInterruptedRun(hostID: fixture.hostID, player: fixture.player)
            #expect(!fixture.controller.isRunning)
            #expect(fixture.controller.unfinished == nil)
        }
    }

    @available(macCatalyst 26.0, *)
    @Test func playingAudioKeepsTranslatingInTheBackground() async throws {
        try await withFixture { fixture in
            fixture.inputs.isPlayingAudio = true
            fixture.start()
            let job = try await readyJob(fixture)
            fixture.controller.sceneChanged(.background, hostID: fixture.hostID)
            #expect(fixture.controller.job?.id == job.id)
            #expect(fixture.narrations.preparationOwner == job.owner)
            #expect(fixture.controller.unfinished?.reason == nil)
        }
    }

    @available(macCatalyst 26.0, *)
    @Test func aRunStillMarkedRunningAtLaunchWasEndedByIOS() async throws {
        try await withFixture { fixture in
            fixture.start()
            _ = try await readyJob(fixture)
            let lastProgress = try #require(fixture.controller.unfinished?.lastProgressAt)

            let relaunched = fixture.relaunchedController()
            #expect(relaunched.unfinished?.reason == .appClosed)
            #expect(relaunched.unfinished?.stoppedAt == lastProgress)
            #expect(relaunched.unfinished?.matches(discourseID: "source", selection: fixture.selection) == true)
            relaunched.forgetUnfinished()
            #expect(fixture.relaunchedController().unfinished == nil)
        }
    }

    @available(macCatalyst 26.0, *)
    @Test func finishingForgetsTheUnfinishedRun() async throws {
        try await withFixture { fixture in
            fixture.start()
            let job = try await readyJob(fixture)
            fixture.controller.finish(.success(fixture.document(for: "source")), attempt: job.lifetime)
            #expect(fixture.controller.unfinished == nil)
            #expect(fixture.relaunchedController().unfinished == nil)
        }
    }

    @available(macCatalyst 26.0, *)
    @Test func savedPassagesAreJoinedWithoutTranslatingOrATap() async throws {
        try await withFixture { fixture in
            try await fixture.saveUnjoinedPassages(for: catalogDiscourse)
            await fixture.controller.joinSavedPassages()
            let joined = try #require(fixture.narrations.documents.first)
            #expect(joined.isComplete)
            #expect(fixture.renderer.rendered.isEmpty)
            #expect(fixture.renderer.assemblyCalls == 1)
            #expect(fixture.narrations.preparationOwner == nil)
            #expect(!fixture.controller.isRunning)
            #expect(fixture.inputs.supportCalls.isEmpty)
        }
    }

    @available(macCatalyst 26.0, *)
    @Test func aTranslationTheListenerStartsStopsAJoinThatIsTriedAgainLater() async throws {
        try await withFixture { fixture in
            try await fixture.saveUnjoinedPassages(for: catalogDiscourse)
            let gate = PreparationControllerGate()
            fixture.inputs.fetchGates[catalogDiscourse] = gate
            let join = Task { await fixture.controller.joinSavedPassages() }
            try await eventually("the join to fetch its transcript") { fixture.inputs.fetchCalls.contains(catalogDiscourse) }

            fixture.start()
            let job = try await readyJob(fixture)
            #expect(fixture.narrations.preparationOwner == job.owner)
            gate.open()
            await join.value
            #expect(fixture.narrations.documents.first { $0.discourseID == catalogDiscourse }?.isComplete == false)
            #expect(fixture.renderer.assemblyCalls == 0)

            fixture.controller.pause()
            await fixture.controller.joinSavedPassages()
            #expect(fixture.narrations.documents.first { $0.discourseID == catalogDiscourse }?.isComplete == true)
        }
    }

    @available(macCatalyst 26.0, *)
    @Test func everyRenditionWaitingToBeJoinedIsJoinedInOnePass() async throws {
        try await withFixture { fixture in
            try await fixture.saveUnjoinedPassages(for: catalogDiscourse)
            try await fixture.saveUnjoinedPassages(for: otherCatalogDiscourse)
            await fixture.controller.joinSavedPassages()
            #expect(fixture.narrations.documents.count == 2)
            #expect(fixture.narrations.documents.filter(\.isComplete).count == 2)
            #expect(fixture.renderer.assemblyCalls == 2)
        }
    }

    @available(macCatalyst 26.0, *)
    @Test func deletingATranslationThatIsRunningStopsItAndNothingRecreatesIt() async throws {
        try await withFixture { fixture in
            try await fixture.saveUnjoinedPassages(for: catalogDiscourse)
            let saved = try #require(fixture.narrations.documents.first)
            fixture.start(catalogDiscourse)
            _ = try await readyJob(fixture)
            try await fixture.controller.delete(saved, player: fixture.player)
            #expect(!fixture.controller.isRunning)
            #expect(fixture.controller.unfinished == nil)
            #expect(fixture.narrations.documents.isEmpty)

            await fixture.controller.joinSavedPassages()
            await fixture.controller.continueInterruptedRun(hostID: fixture.hostID, player: fixture.player)
            #expect(!fixture.controller.isRunning)
            #expect(fixture.narrations.documents.isEmpty)
        }
    }

    @available(macCatalyst 26.0, *)
    @Test func aJoinThatFailsIsNotRetriedInTheSameLaunch() async throws {
        try await withFixture { fixture in
            try await fixture.saveUnjoinedPassages(for: catalogDiscourse)
            fixture.renderer.beforeAssembly = { _, _ in throw PreparationControllerTestError.fetch }
            await fixture.controller.joinSavedPassages()
            #expect(fixture.renderer.assemblyCalls == 1)
            #expect(fixture.narrations.preparationOwner == nil)
            await fixture.controller.joinSavedPassages()
            #expect(fixture.renderer.assemblyCalls == 1)
        }
    }

    @available(macCatalyst 26.0, *)
    private func withFixture(_ body: @MainActor (PreparationControllerFixture) async throws -> Void) async throws {
        let fixture = try PreparationControllerFixture()
        defer { fixture.remove() }
        try await body(fixture)
    }

    @available(macCatalyst 26.0, *)
    private func readyJob(_ fixture: PreparationControllerFixture) async throws -> NarrationTranslationJob {
        try await eventually("a translation job") { fixture.controller.job != nil }
        return try #require(fixture.controller.job)
    }

    private func eventually(_ description: String, condition: @MainActor () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !condition() {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                Issue.record("Timed out waiting for \(description)")
                throw PreparationControllerTestError.timedOut
            }
            await Task.yield()
        }
    }
}

@available(macCatalyst 26.0, *)
@MainActor
private final class PreparationControllerFixture {
    let suite: String
    let directory: URL
    let defaults: UserDefaults
    let narrations: NarrationService
    let player: AudioPlayerService
    let inputs: PreparationControllerInputs
    let controller: NarrationPreparationController
    let renderer = NarrationTestRenderer()
    let hostID = UUID()
    let selection = NarrationSelection(
        sourceLanguage: "en", targetLanguage: "fr",
        voice: NarrationVoice(id: "test-fr", name: "Test French", language: "fr-FR", quality: 1)
    )

    init() throws {
        let suite = "NarrationPreparationControllerTests.\(UUID().uuidString)"
        self.suite = suite
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defaults = try #require(UserDefaults(suiteName: suite))
        narrations = NarrationService(directory: directory, defaults: defaults)
        player = AudioPlayerService(settings: nil, connectsToSystem: false, narrationService: narrations)
        let inputs = PreparationControllerInputs()
        self.inputs = inputs
        controller = NarrationPreparationController(
            narrations: narrations,
            findSupport: { try await inputs.findSupport(source: $0, target: $1) },
            fetchTranscript: { try await inputs.fetchTranscript($0) },
            isPlayingAudio: { inputs.isPlayingAudio },
            defaults: defaults,
            makeRenderer: { [renderer] _ in renderer }
        )
    }

    /// Every passage saved, as when the app stopped just before joining them into one file.
    func saveUnjoinedPassages(for discourseID: String) async throws {
        let transcript = try await inputs.fetchTranscript(discourseID)
        inputs.fetchCalls.removeAll()
        let unjoined = NarrationTestRenderer()
        unjoined.beforeAssembly = { _, _ in throw PreparationControllerTestError.fetch }
        _ = try? await narrations.prepare(
            transcript: transcript, selection: selection, translate: { $0.map { "Traduit : " + $0 } }, renderer: unjoined
        )
        let saved = try #require(narrations.documents.first { $0.discourseID == discourseID })
        #expect(!saved.isComplete && saved.segments.count == saved.expectedSegmentCount)
    }

    /// A fresh controller over the same saved state, as after the app is relaunched.
    func relaunchedController() -> NarrationPreparationController {
        NarrationPreparationController(
            narrations: narrations,
            findSupport: { [inputs] in try await inputs.findSupport(source: $0, target: $1) },
            fetchTranscript: { [inputs] in try await inputs.fetchTranscript($0) },
            isPlayingAudio: { [inputs] in inputs.isPlayingAudio },
            defaults: defaults
        )
    }

    func start(_ discourseID: String = "source", hostID: UUID? = nil) {
        controller.start(
            discourseID: discourseID, selection: selection, hostID: hostID ?? self.hostID,
            player: player, listen: false
        )
    }

    func makeController() -> NarrationPreparationController {
        NarrationPreparationController(
            narrations: narrations,
            findSupport: { [inputs] in try await inputs.findSupport(source: $0, target: $1) },
            fetchTranscript: { [inputs] in try await inputs.fetchTranscript($0) }
        )
    }

    func document(for discourseID: String) -> NarrationDocument {
        NarrationDocument(
            id: "prepared-\(discourseID)", discourseID: discourseID, sourceDigest: "test-digest",
            selection: selection, expectedSegmentCount: 1,
            segments: [.init(index: 0, sourceParagraphIndex: 0, text: "Un passage.", audioFileName: "0.m4a", duration: 1)],
            audioFileName: "narration.m4a", duration: 1, updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    func remove() {
        controller.pause()
        inputs.supportGate?.open()
        inputs.fetchGates.values.forEach { $0.open() }
        player.stop()
        narrations.cancel()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@available(macCatalyst 26.0, *)
@MainActor
private final class PreparationControllerInputs {
    var support: NarrationTranslationSupport? = .init(strategy: .standard, status: .installed)
    var supportGate: PreparationControllerGate?
    var fetchGates: [String: PreparationControllerGate] = [:]
    var fetchErrors: [String: any Error] = [:]
    var supportCalls: [(source: String, target: String)] = []
    var completedSupportCalls = 0
    var fetchCalls: [String] = []
    var completedFetches: [String] = []
    var isPlayingAudio = false

    func findSupport(source: String, target: String) async throws -> NarrationTranslationSupport? {
        supportCalls.append((source, target))
        defer { completedSupportCalls += 1 }
        await supportGate?.wait()
        return support
    }

    func fetchTranscript(_ discourseID: String) async throws -> Transcript {
        fetchCalls.append(discourseID)
        defer { completedFetches.append(discourseID) }
        await fetchGates[discourseID]?.wait()
        if let error = fetchErrors[discourseID] { throw error }
        return Transcript(
            discourseID: discourseID, sourceID: "test-source", fetchedAt: Date(timeIntervalSince1970: 1),
            paragraphs: [.init(index: 0, text: "A source paragraph.", isEmphasis: false)]
        )
    }
}

@MainActor
private final class PreparationControllerGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    // A retired native request can still return; cancellation must be fenced by the controller.
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private enum PreparationControllerTestError: Error {
    case fetch, timedOut
}
#endif
