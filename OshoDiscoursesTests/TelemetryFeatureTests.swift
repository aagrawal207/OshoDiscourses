import Foundation
import StoreKit
import Testing
@testable import OshoDiscourses

/// Feature signals sent through the shared service. Each body that records runs
/// without suspending, so a test in another suite cannot swap the shared sink midway.
extension SharedTelemetrySuites {
    @Suite(.serialized)
    @MainActor
    struct TelemetryFeatureTests {
        private let bird1 = "english-A_Bird_on_the_Wing__-1"

        // MARK: Bookmarks

        @Test func addingABookmarkSendsFlagsNotItsText() throws {
            try withBookmarks { bookmarks in
                try withSharedTelemetry { sink in
                    bookmarks.add(
                        discourseID: bird1, seriesName: "A Bird on the Wing", title: "A Bird on the Wing #1",
                        timestamp: 120, note: "my private thought", category: .custom, customCategory: "secret tag"
                    )
                    bookmarks.add(discourseID: bird1, seriesName: "A Bird on the Wing", title: "A Bird on the Wing #1",
                                  timestamp: 240, note: "  ", category: .profound)

                    let added = sink.named(.bookmarkAdded)
                    #expect(added.count == 2)
                    let custom = try #require(added.first)
                    #expect(custom.parameters["discourseID"] == bird1)
                    #expect(custom.parameters["seriesID"] == "english-A_Bird_on_the_Wing__")
                    #expect(custom.parameters["hasNote"] == "true")
                    #expect(custom.parameters["category"] == "Custom")
                    #expect(added.last?.parameters["hasNote"] == "false")
                    #expect(added.last?.parameters["category"] == "Profound")
                    let values = added.flatMap(\.parameters.values)
                    #expect(!values.contains { $0.contains("private") || $0.contains("secret") })
                }
            }
        }

        @Test func deletingABookmarkSendsOnceAndAnUnknownIDSendsNothing() throws {
            try withBookmarks { bookmarks in
                bookmarks.add(discourseID: bird1, seriesName: "A Bird on the Wing", title: "#1", timestamp: 10, category: .funny)
                let id = try #require(bookmarks.bookmarks.first?.id)
                withSharedTelemetry { sink in
                    bookmarks.remove(id: id)
                    bookmarks.remove(id: id)
                    bookmarks.remove(id: "missing")
                    let deleted = sink.named(.bookmarkDeleted)
                    #expect(deleted.count == 1)
                    #expect(deleted.first?.parameters["discourseID"] == bird1)
                    #expect(deleted.first?.parameters["category"] == "Funny")
                }
            }
        }

        @Test func bookmarksArrivingFromICloudAreNotCountedAsAdded() {
            withBookmarks { bookmarks in
                withSharedTelemetry { sink in
                    let incoming = Bookmark(discourseID: bird1, seriesName: "A Bird on the Wing", title: "#1", timestamp: 30)
                    #expect(bookmarks.mergeSyncedBookmarks([incoming]))
                    #expect(bookmarks.bookmarks.count == 1)
                    #expect(sink.named(.bookmarkAdded).isEmpty)
                }
            }
        }

        // MARK: Tips

        @Test func tipOutcomesAreSentWithoutMessages() async {
            await withTips { tips in
                await withSharedTelemetry { sink in
                    let product = TipJarService.productIDs[0]
                    await tips.purchase(productID: product, type: .consumable) { .thanked }
                    tips.dismissMessage()
                    await tips.purchase(productID: product, type: .consumable) { throw StoreKitError.userCancelled }
                    await tips.purchase(productID: product, type: .consumable) { .pending }
                    tips.dismissMessage()
                    await tips.purchase(productID: product, type: .consumable) { throw Product.PurchaseError.purchaseNotAllowed }
                    tips.dismissMessage()
                    await tips.purchase(productID: "unrelated.product", type: .consumable) { .thanked }

                    let purchases = sink.named(.supportPurchase)
                    #expect(purchases.map { $0.parameters["outcome"] } == ["completed", "cancelled", "pending", "failed"])
                    #expect(purchases.allSatisfy { $0.parameters["kind"] == "tip" && $0.parameters["product"] == product })
                    #expect(purchases.last?.parameters["failure"] == "restricted")
                    #expect(purchases.allSatisfy { Set($0.parameters.keys).isSubset(of: ["product", "kind", "outcome", "failure"]) })
                }
            }
        }

        @Test func aBusyTipJarSendsNoPurchase() async {
            await withTips { tips in
                let product = TipJarService.productIDs[0]
                await tips.purchase(productID: product, type: .consumable) { .thanked }
                await withSharedTelemetry { sink in
                    await tips.purchase(productID: product, type: .consumable) { .thanked }
                    #expect(sink.named(.supportPurchase).isEmpty)
                }
            }
        }

        // MARK: Yearly support

        @Test func yearlyPurchaseOutcomesAreSent() async {
            let product = AnnualSupportService.productIDs[0]
            let service = AnnualSupportService(loadStatuses: { _ in [] })
            await service.refreshStatus()
            await withSharedTelemetry { sink in
                await service.purchase(productID: product, type: .autoRenewable) { .pending }
                service.clearDeclinedRequest()
                await service.purchase(productID: product, type: .autoRenewable) { throw StoreKitError.userCancelled }
                await service.purchase(productID: product, type: .autoRenewable) { throw URLError(.timedOut) }
                service.dismissMessage()
                await service.purchase(productID: product, type: .autoRenewable) { .thanked }
                await service.purchase(productID: "unknown", type: .autoRenewable) { .thanked }

                let purchases = sink.named(.supportPurchase)
                #expect(purchases.map { $0.parameters["outcome"] } == ["pending", "cancelled", "failed", "completed"])
                #expect(purchases.allSatisfy { $0.parameters["kind"] == "yearly" && $0.parameters["product"] == product })
            }
        }

        @Test func restoreOutcomesAreSent() async {
            let product = AnnualSupportService.productIDs[1]
            let store = RestoreStatuses(statuses: [.init(productID: product, state: .subscribed)])
            let service = AnnualSupportService(loadStatuses: { _ in store.statuses })
            await withSharedTelemetry { sink in
                await service.restore(using: {})
                store.statuses = []
                await service.restore(using: {})
                await service.restore { throw StoreKitError.userCancelled }
                await service.restore { throw URLError(.notConnectedToInternet) }

                let restores = sink.named(.supportPurchase)
                #expect(restores.map { $0.parameters["outcome"] } == ["restored", "nothingToRestore", "restoreCancelled", "restoreFailed"])
                #expect(restores.first?.parameters["product"] == product)
                #expect(restores.allSatisfy { $0.parameters["kind"] == "yearly" })
            }
        }

        // MARK: Support prompt

        @Test func supportPromptActionsAreSent() {
            let context = EngagementService.SupportContext(
                activeDays: 7, totalListening: 7_200, subscriptionStatus: .notSubscribed,
                isForeground: true, isHomeVisible: true
            )
            withSharedTelemetry { sink in
                withEngagement { engagement in
                    let owner = UUID()
                    #expect(engagement.beginSupportPresentation(owner: owner, context: context))
                    #expect(engagement.recordSupportExposure(owner: owner, context: context))
                    #expect(engagement.recordSupportExposure(owner: owner, context: context))
                    engagement.dismissSupport(owner: owner, context: context, permanently: false)
                }
                withEngagement { engagement in
                    let owner = UUID()
                    engagement.beginSupportPresentation(owner: owner, context: context)
                    #expect(engagement.openSupportSheet(owner: owner, context: context))
                }
                withEngagement { engagement in
                    let owner = UUID()
                    engagement.beginSupportPresentation(owner: owner, context: context)
                    engagement.dismissSupport(owner: owner, context: context, permanently: true)
                }
                #expect(sink.named(.supportPrompt).map { $0.parameters["action"] } == [
                    "shown", "notNow", "shown", "accepted", "shown", "dontAskAgain",
                ])
            }
        }

        // MARK: Review

        @Test func aReviewIsSentOnlyWhenTheSystemIsAsked() {
            withSharedTelemetry { sink in
                withEngagement { engagement in
                    withDefaults { defaults in
                        var requests = 0
                        #expect(!attemptReview(activeDays: 2, defaults: defaults, engagement: engagement) { requests += 1 })
                        #expect(!attemptReview(activeDays: 5, isPlaying: true, defaults: defaults, engagement: engagement) { requests += 1 })
                        #expect(sink.named(.reviewRequested).isEmpty)
                        #expect(attemptReview(activeDays: 5, defaults: defaults, engagement: engagement) { requests += 1 })
                        #expect(!attemptReview(activeDays: 5, defaults: defaults, engagement: engagement) { requests += 1 })
                        #expect(requests == 1)
                        #expect(sink.named(.reviewRequested).map { $0.parameters } == [["activeDays": "2-5"]])
                    }
                }
            }
        }

        // MARK: What's New

        @Test func whatsNewIsSentOncePerPresentation() {
            let releases = [
                AppRelease(version: "1.17.0", items: ["Translation"], highlights: nil),
                AppRelease(version: "1.16.3", items: ["Speed"], highlights: nil),
                AppRelease(version: "1.16.2", items: ["Copy"], highlights: nil),
            ]
            withDefaults { defaults in
                withDefaults { freshDefaults in
                    defaults.set("1.16.2", forKey: WhatsNewService.lastSeenKey)
                    let service = WhatsNewService(defaults: defaults, installedVersion: "1.17.0", releases: releases)
                    let fresh = WhatsNewService(defaults: freshDefaults, installedVersion: "1.17.0", releases: releases,
                                                hasPriorUse: { false })
                    withSharedTelemetry { sink in
                        let owner = UUID()
                        #expect(service.claimPresentation(owner: owner))
                        #expect(service.claimPresentation(owner: owner))
                        #expect(!service.claimPresentation(owner: UUID()))
                        service.finishPresentation(owner: owner)
                        #expect(!service.claimPresentation(owner: owner))
                        #expect(!fresh.claimPresentation(owner: UUID()))
                        #expect(sink.named(.whatsNewShown).map { $0.parameters } == [["version": "1.17.0", "skippedReleases": "1"]])
                    }
                }
            }
        }

        // MARK: Translation

        @Test func deletedTranslationsCarryLanguagesNotText() {
            let document = NarrationDocument(
                id: "deleted", discourseID: bird1, sourceDigest: "digest",
                selection: NarrationSelection(
                    sourceLanguage: "en", targetLanguage: "hi",
                    voice: NarrationVoice(id: "com.apple.voice.personal.123", name: "Mine", language: "hi-IN", quality: 2)
                ),
                expectedSegmentCount: 1,
                segments: [.init(index: 0, sourceParagraphIndex: 0, text: "Passage text", audioFileName: "0.m4a", duration: 400)],
                audioFileName: "narration.m4a", duration: 400, updatedAt: Date()
            )
            let parameters = NarrationService.deletedTelemetryParameters(document)
            #expect(parameters["discourseID"] == bird1)
            #expect(parameters["sourceLanguage"] == "en")
            #expect(parameters["targetLanguage"] == "hi")
            #expect(parameters["complete"] == "true")
            #expect(parameters["minutes"] == "5-15")
            #expect(!parameters.values.contains { $0.contains("Passage") || $0.contains("voice") || $0.contains("Mine") })
        }

        #if TRANSLATED_NARRATION
        @available(macCatalyst 26.0, *)
        @Test func startingATranslationSendsItsLanguagesButNoVoiceID() throws {
            let fixture = try TranslationTelemetryFixture()
            defer { fixture.remove() }
            try withSharedTelemetry { sink in
                fixture.controller.start(
                    discourseID: bird1, selection: fixture.selection, hostID: fixture.hostID, player: fixture.player,
                    listen: true, automatic: false
                )
                let started = try #require(sink.named(.translationStarted).first)
                #expect(started.parameters["discourseID"] == bird1)
                #expect(started.parameters["sourceLanguage"] == "en")
                #expect(started.parameters["targetLanguage"] == "fr")
                #expect(started.parameters["automatic"] == "false")
                #expect(started.parameters["listen"] == "true")
                #expect(started.parameters["resumed"] == "false")
                #expect(started.parameters["pace"] == "natural")
                #expect(started.parameters["voiceQuality"] == "1")
                #expect(!started.parameters.values.contains("test-fr"))
            }
        }

        @available(macCatalyst 26.0, *)
        @Test func eachRunSendsOneOutcome() throws {
            let fixture = try TranslationTelemetryFixture()
            defer { fixture.remove() }
            try withSharedTelemetry { sink in
                fixture.start()
                let ready = try #require(fixture.controller.lifetime)
                fixture.controller.finish(.success(fixture.document()), attempt: ready)
                fixture.controller.finish(.success(fixture.document()), attempt: ready)

                fixture.start()
                fixture.controller.finish(.failure(TranslationTelemetryError.failed), attempt: try #require(fixture.controller.lifetime))

                fixture.start()
                fixture.controller.finish(.failure(CancellationError()), attempt: try #require(fixture.controller.lifetime))

                fixture.start()
                fixture.controller.pause()
                fixture.controller.pause()

                let outcomes = sink.named(.translationFinished)
                try #require(outcomes.count == 4)
                #expect(outcomes.map { $0.parameters["outcome"] } == ["ready", "failed", "cancelled", "paused"])
                #expect(outcomes[0].parameters["minutes"] == "<1")
                #expect(outcomes[0].parameters["audioMinutes"] == "<1")
                #expect(outcomes[1].parameters["stage"] == "checkingSupport")
                #expect(outcomes[2].parameters["reason"] == "interrupted")
                #expect(outcomes[3].parameters["reason"] == "paused")
                #expect(outcomes.allSatisfy { $0.parameters["targetLanguage"] == "fr" })
                #expect(sink.named(.translationConsent).isEmpty)
            }
        }

        @available(macCatalyst 26.0, *)
        @Test func consentAcceptedIsSent() async throws {
            let fixture = try TranslationTelemetryFixture()
            defer { fixture.remove() }
            let job = try await fixture.jobAwaitingConsent()
            withSharedTelemetry { sink in
                fixture.controller.languagesAllowed(for: job)
                fixture.controller.languagesAllowed(for: job)
                #expect(sink.named(.translationConsent).map { $0.parameters["result"] } == ["accepted"])
                #expect(sink.named(.translationFinished).isEmpty)
            }
        }

        @available(macCatalyst 26.0, *)
        @Test func consentDeclinedEndsTheRun() async throws {
            let fixture = try TranslationTelemetryFixture()
            defer { fixture.remove() }
            let job = try await fixture.jobAwaitingConsent()
            withSharedTelemetry { sink in
                fixture.controller.finish(.failure(CancellationError()), attempt: job.lifetime)
                #expect(sink.named(.translationConsent).map { $0.parameters["result"] } == ["declined"])
                #expect(sink.named(.translationFinished).map { $0.parameters["outcome"] } == ["cancelled"])
            }
        }

        @available(macCatalyst 26.0, *)
        @Test func closingTheSheetBeforeConsentIsSent() async throws {
            let fixture = try TranslationTelemetryFixture()
            defer { fixture.remove() }
            _ = try await fixture.jobAwaitingConsent()
            withSharedTelemetry { sink in
                fixture.controller.listeningSheetDisappeared(fixture.sheetID)
                #expect(sink.named(.translationConsent).map { $0.parameters["result"] } == ["sheetClosed"])
                let finished = sink.named(.translationFinished)
                #expect(finished.map { $0.parameters["outcome"] } == ["paused"])
                #expect(finished.first?.parameters["reason"] == "interrupted")
                #expect(finished.first?.parameters["stage"] == "preparingLanguages")
            }
        }
        #endif

        // MARK: Helpers

        private func withBookmarks(_ body: (BookmarkService) throws -> Void) rethrows {
            let suite = "TelemetryFeatureTests.bookmarks.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).json")
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: file)
            }
            try body(BookmarkService(fileURL: file, defaults: defaults))
        }

        private func withTips(_ body: (TipJarService) async -> Void) async {
            let suite = "TelemetryFeatureTests.tips.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            await body(TipJarService(defaults: defaults))
        }

        private func withDefaults(_ body: (UserDefaults) -> Void) {
            let suite = "TelemetryFeatureTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            body(defaults)
        }

        private func withEngagement(_ body: (EngagementService) -> Void) {
            let suite = "TelemetryFeatureTests.engagement.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            body(EngagementService(defaults: defaults, now: { Date(timeIntervalSince1970: 1_800_000_000) }))
        }

        private func attemptReview(
            activeDays: Int, isPlaying: Bool = false, defaults: UserDefaults, engagement: EngagementService,
            request: () -> Void
        ) -> Bool {
            ReviewRequestService.attemptReview(
                activeDays: activeDays, currentVersion: "2.0", defaults: defaults, engagement: engagement,
                isForeground: true, isPlaying: isPlaying, sleepTimerArmed: false, request: request
            )
        }
    }

    private enum TranslationTelemetryError: Error {
        case failed, timedOut
    }

    @MainActor
    private final class RestoreStatuses {
        var statuses: [AnnualSupportService.Status]
        init(statuses: [AnnualSupportService.Status]) { self.statuses = statuses }
    }

    #if TRANSLATED_NARRATION
    @available(macCatalyst 26.0, *)
    @MainActor
    private final class TranslationTelemetryFixture {
        let suite: String
        let directory: URL
        let defaults: UserDefaults
        let narrations: NarrationService
        let player: AudioPlayerService
        let controller: NarrationPreparationController
        let hostID = UUID()
        let sheetID = UUID()
        let discourseID = "telemetry-source"
        private let inputs: TranslationTelemetryInputs
        let selection = NarrationSelection(
            sourceLanguage: "en", targetLanguage: "fr",
            voice: NarrationVoice(id: "test-fr", name: "Test French", language: "fr-FR", quality: 1)
        )

        init() throws {
            let suite = "TelemetryFeatureTests.translation.\(UUID().uuidString)"
            self.suite = suite
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
            defaults = try #require(UserDefaults(suiteName: suite))
            narrations = NarrationService(directory: directory, defaults: defaults)
            player = AudioPlayerService(settings: nil, connectsToSystem: false, narrationService: narrations)
            let inputs = TranslationTelemetryInputs()
            self.inputs = inputs
            controller = NarrationPreparationController(
                narrations: narrations,
                findSupport: { _, _ in inputs.support },
                fetchTranscript: { id in
                    Transcript(
                        discourseID: id, sourceID: "test-source", fetchedAt: Date(timeIntervalSince1970: 1),
                        paragraphs: [.init(index: 0, text: "A source paragraph.", isEmphasis: false)]
                    )
                },
                isPlayingAudio: { false },
                defaults: defaults
            )
        }

        func start() {
            controller.start(discourseID: discourseID, selection: selection, hostID: hostID, player: player, listen: false)
        }

        /// A run whose languages need Apple's download prompt, asked for by an open listening sheet.
        func jobAwaitingConsent() async throws -> NarrationTranslationJob {
            inputs.support = .init(strategy: .standard, status: .supported)
            controller.listeningSheetAppeared(sheetID, hostID: hostID, discourseID: discourseID)
            start()
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while controller.job == nil || !controller.awaitingConsent {
                guard ContinuousClock.now < deadline else { throw TranslationTelemetryError.timedOut }
                await Task.yield()
            }
            return try #require(controller.job)
        }

        func document() -> NarrationDocument {
            NarrationDocument(
                id: "prepared", discourseID: discourseID, sourceDigest: "digest", selection: selection,
                expectedSegmentCount: 1,
                segments: [.init(index: 0, sourceParagraphIndex: 0, text: "Un passage.", audioFileName: "0.m4a", duration: 1)],
                audioFileName: "narration.m4a", duration: 1, updatedAt: Date(timeIntervalSince1970: 1)
            )
        }

        func remove() {
            controller.pause()
            player.stop()
            narrations.cancel()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @available(macCatalyst 26.0, *)
    @MainActor
    private final class TranslationTelemetryInputs {
        var support = NarrationTranslationSupport(strategy: .standard, status: .installed)
    }
    #endif
}
