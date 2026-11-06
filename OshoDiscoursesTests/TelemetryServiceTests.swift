import Foundation
import Testing
@testable import OshoDiscourses

extension SharedTelemetrySuites {
    @Suite(.serialized)
    @MainActor
    struct TelemetryServiceTests {
        private let bird1 = "english-A_Bird_on_the_Wing__-1"
        private let bird2 = "english-A_Bird_on_the_Wing__-2"

        private func makeService(
            sink: RecordingTelemetrySink = RecordingTelemetrySink(),
            now: @escaping () -> Date = Date.init,
            enabled: Bool = true
        ) -> (TelemetryService, RecordingTelemetrySink, UserDefaults) {
            let defaults = UserDefaults(suiteName: "TelemetryServiceTests.\(UUID())")!
            let service = TelemetryService(
                sink: sink, defaults: defaults, now: now,
                rateDebounce: .milliseconds(50), searchDebounce: .milliseconds(50)
            )
            service.start(enabled: enabled)
            return (service, sink, defaults)
        }

        // MARK: Opt-out

        @Test func disabledServiceNeverStartsOrSends() {
            let (service, sink, _) = makeService(enabled: false)
            service.send(.bookmarkAdded)
            service.playbackStarted(bird1, kind: .original, reason: .user, rate: 1)
            service.addListening(seconds: 60)
            service.playbackFinished(naturally: true)
            #expect(sink.startCount == 0)
            #expect(sink.signals.isEmpty)
            #expect(!service.isRunning)
        }

        @Test func startUsesTheConfiguredNamespace() {
            let (_, sink, _) = makeService()
            #expect(sink.startCount == 1)
            #expect(sink.namespace == "com.abhishekagrawal")
        }

        @Test func turningOffStopsTheSDKAndDropsTheOpenListen() {
            let (service, sink, _) = makeService()
            service.playbackStarted(bird1, kind: .original, reason: .user, rate: 1)
            service.addListening(seconds: 90)
            service.setEnabled(false)
            #expect(sink.stopCount == 1)
            service.setEnabled(true)
            service.flushListening(trigger: .stopped)
            #expect(sink.named(.listeningSession).isEmpty)
            #expect(sink.startCount == 2)
        }

        @Test func theRealSinkNeverStartsInsideTheUnitTestHost() {
            let sink = RecordingTelemetrySink(isTestSink: false)
            let (service, _, _) = makeService(sink: sink)
            #expect(sink.startCount == 0)
            #expect(!service.isRunning)
        }

        @Test func contextIsReadByTheSDKDefaultParameters() throws {
            let (service, sink, _) = makeService()
            service.updateContext(["Settings.noiseReductionMode": "rnnoise"])
            let defaultParameters = try #require(sink.defaultParameters)
            let parameters = defaultParameters()
            #expect(parameters["Settings.noiseReductionMode"] == "rnnoise")
        }

        // MARK: Listening

        @Test func aFinishedTalkSendsOneSegmentWithItsSeconds() throws {
            let (service, sink, _) = makeService()
            service.playbackStarted(bird1, kind: .original, reason: .user, rate: 1.25)
            service.addListening(seconds: 600)
            service.noteListening(.skipForward)
            service.noteListening(.skipBack)
            service.noteListening(.skipBack)
            service.noteListening(.seek)
            service.playbackFinished(naturally: true)

            let segment = try #require(sink.named(.listeningSession).first)
            #expect(sink.named(.listeningSession).count == 1)
            #expect(segment.value == 600)
            #expect(segment.parameters["discourseID"] == bird1)
            #expect(segment.parameters["seriesID"] == "english-A_Bird_on_the_Wing__")
            #expect(segment.parameters["language"] == "english")
            #expect(segment.parameters["kind"] == "original")
            #expect(segment.parameters["startReason"] == "user")
            #expect(segment.parameters["endTrigger"] == "finished")
            #expect(segment.parameters["completed"] == "true")
            #expect(segment.parameters["skipsForward"] == "1")
            #expect(segment.parameters["skipsBack"] == "2-5")
            #expect(segment.parameters["seeks"] == "1")
            #expect(segment.parameters["rate"] == "1.25")
            #expect(segment.parameters["minutes"] == "5-15")
        }

        @Test func startingAnotherTalkSendsThePreviousOneAsSwitched() throws {
            let (service, sink, _) = makeService()
            service.playbackStarted(bird1, kind: .original, reason: .user, rate: 1)
            service.addListening(seconds: 30)
            service.playbackStarted(bird2, kind: .original, reason: .autoAdvance, rate: 1)

            let segments = sink.named(.listeningSession)
            #expect(segments.count == 1)
            #expect(segments.first?.parameters["discourseID"] == bird1)
            #expect(segments.first?.parameters["endTrigger"] == "switched")
            #expect(segments.first?.parameters["completed"] == "false")
        }

        @Test func aSkipToTheEndIsNotCompleted() throws {
            let (service, sink, _) = makeService()
            service.playbackStarted(bird1, kind: .original, reason: .user, rate: 1)
            service.addListening(seconds: 30)
            service.playbackFinished(naturally: false)
            let segment = try #require(sink.named(.listeningSession).first)
            #expect(segment.parameters["completed"] == "false")
            #expect(segment.parameters["endTrigger"] == "skippedToEnd")
        }

        @Test func aTalkLeftWithinASecondIsNotSent() {
            let (service, sink, _) = makeService()
            service.playbackStarted(bird1, kind: .original, reason: .user, rate: 1)
            service.addListening(seconds: 0.5)
            service.playbackStarted(bird2, kind: .original, reason: .user, rate: 1)
            #expect(sink.named(.listeningSession).isEmpty)
        }

        @Test func translationSegmentsCarryTheirLanguages() throws {
            let (service, sink, _) = makeService()
            service.playbackStarted(bird1, kind: .translation(source: "en", target: "hi"), reason: .user, rate: 1)
            service.addListening(seconds: 120)
            service.flushListening(trigger: .stopped)
            let segment = try #require(sink.named(.listeningSession).first)
            #expect(segment.parameters["kind"] == "translation")
            #expect(segment.parameters["sourceLanguage"] == "en")
            #expect(segment.parameters["targetLanguage"] == "hi")
        }

        @Test func aLongListenIsSentInPartsAndKeepsCounting() {
            let (service, sink, _) = makeService()
            service.playbackStarted(bird1, kind: .original, reason: .user, rate: 1)
            service.addListening(seconds: TelemetryService.listeningFlushSeconds)
            #expect(sink.named(.listeningSession).count == 1)
            #expect(sink.named(.listeningSession).first?.parameters["endTrigger"] == "periodic")

            service.addListening(seconds: 120)
            service.playbackFinished(naturally: true)
            let segments = sink.named(.listeningSession)
            #expect(segments.count == 2)
            #expect(segments.last?.parameters["startReason"] == "continued")
            #expect(segments.last?.value == 120)
        }

        @Test func backgroundFlushContinuesOnlyWhilePlaying() {
            let (service, sink, _) = makeService()
            service.playbackStarted(bird1, kind: .original, reason: .user, rate: 1)
            service.addListening(seconds: 60)
            service.flushListening(trigger: .background, continuing: true)
            service.addListening(seconds: 30)
            service.flushListening(trigger: .background, continuing: false)
            service.addListening(seconds: 30)
            service.flushListening(trigger: .stopped)

            let segments = sink.named(.listeningSession)
            #expect(segments.map(\.value) == [60, 30])
            #expect(segments.map { $0.parameters["endTrigger"] } == ["background", "background"])
        }

        @Test func resumeOpensASegmentOnlyWhenNoneIsOpen() {
            let (service, sink, _) = makeService()
            service.playbackStarted(bird1, kind: .original, reason: .user, rate: 1)
            service.addListening(seconds: 40)
            service.playbackResumed(bird1, kind: .original, rate: 1)
            service.flushListening(trigger: .background)
            service.playbackResumed(bird1, kind: .original, rate: 1)
            service.addListening(seconds: 20)
            service.flushListening(trigger: .stopped)

            let segments = sink.named(.listeningSession)
            #expect(segments.map(\.value) == [40, 20])
            #expect(segments.map { $0.parameters["startReason"] } == ["user", "continued"])
        }

        // MARK: Debounced signals

        @Test func onlyTheSettledSpeedIsSent() async throws {
            let (service, sink, _) = makeService()
            service.playbackRateChanged(1.05)
            service.playbackRateChanged(1.1)
            service.playbackRateChanged(1.15)
            try await Task.sleep(for: .milliseconds(200))
            #expect(sink.named(.speedChanged).map { $0.parameters["rate"] } == ["1.15"])
        }

        @Test func librarySearchSendsLengthsNotText() async throws {
            let (service, sink, _) = makeService()
            service.librarySearchChanged(queryLength: 3, resultCount: 40)
            service.librarySearchChanged(queryLength: 4, resultCount: 12)
            try await Task.sleep(for: .milliseconds(200))
            let search = try #require(sink.named(.librarySearched).first)
            #expect(sink.named(.librarySearched).count == 1)
            #expect(search.parameters == ["queryLength": "2-5", "results": "11-25"])
        }

        @Test func clearingTheSearchCancelsThePendingSignal() async throws {
            let (service, sink, _) = makeService()
            service.librarySearchChanged(queryLength: 3, resultCount: 40)
            service.librarySearchChanged(queryLength: 0, resultCount: 351)
            try await Task.sleep(for: .milliseconds(200))
            #expect(sink.named(.librarySearched).isEmpty)
        }

        // MARK: Downloads and snapshot

        @Test func downloadOriginIsTakenOnce() {
            let (service, _, _) = makeService()
            service.noteDownloadOrigin(bird1, .smartDownload)
            #expect(service.takeDownloadOrigin(bird1) == .smartDownload)
            #expect(service.takeDownloadOrigin(bird1) == .unknown)
        }

        // MARK: Summary

        @Test func eventsAreCountedNotSent() {
            let (service, sink, _) = makeService()
            service.send(.bookmarkAdded, ["discourseID": bird1, "category": "Funny", "hasNote": "true"])
            service.send(.bookmarkAdded, ["discourseID": bird2, "category": "Funny", "hasNote": "false"])
            service.send(.seriesOpened, ["seriesID": "english-A_Bird_on_the_Wing__"])

            #expect(sink.sent.isEmpty)
            #expect(sink.named(.bookmarkAdded).count == 2)
            #expect(service.pendingCounters["Bookmark.added"] == 2)
            #expect(service.pendingCounters["Bookmark.added.category.Funny"] == 2)
            #expect(service.pendingCounters["Bookmark.added.hasNote.true"] == 1)
            #expect(service.pendingCounters["Series.opened"] == 1)
            #expect(service.pendingCounters.keys.allSatisfy { !$0.contains(bird1) })
        }

        @Test func purchasesAreSentAtOnce() {
            let (service, sink, _) = makeService()
            service.send(.supportPurchase, ["product": "com.agraabhi.oshodiscourses.tip.small", "outcome": "completed"])
            #expect(sink.sentNamed(.supportPurchase).count == 1)
            #expect(service.pendingCounters.isEmpty)
        }

        @Test func aSummaryCarriesCountsMinutesAndTheTalksHeard() throws {
            var clock = Date(timeIntervalSince1970: 1_800_000_000)
            let (service, sink, _) = makeService(now: { clock })
            service.librarySizes = { ["Library.downloads": "2-5"] }
            service.playbackStarted(bird1, kind: .original, reason: .user, rate: 1)
            service.addListening(seconds: 900)
            service.noteListening(.skipForward)
            service.playbackFinished(naturally: true)
            service.playbackStarted(bird2, kind: .original, reason: .autoAdvance, rate: 1)
            service.addListening(seconds: 30)
            service.flushListening(trigger: .stopped)
            service.send(.sleepTimerStarted, ["option": "30"])
            clock += 3600

            service.sendSummaryIfDue(trigger: .background)

            let summary = try #require(sink.sentNamed(.usageSummary).first)
            #expect(summary.value == 16)
            #expect(summary.parameters["Listening.minutes"] == "16")
            #expect(summary.parameters["Listening.original.minutes"] == "16")
            #expect(summary.parameters["Listening.starts.user"] == "1")
            #expect(summary.parameters["Listening.starts.autoAdvance"] == "1")
            #expect(summary.parameters["Listening.completed"] == "1")
            #expect(summary.parameters["Listening.skipsForward"] == "1")
            #expect(summary.parameters["SleepTimer.started.option.30"] == "1")
            #expect(summary.parameters["Library.downloads"] == "2-5")
            #expect(summary.parameters["trigger"] == "background")
            #expect(summary.parameters["periodHours"] == "1")

            // The 30-second listen is only in the totals.
            let talks = sink.sentNamed(.listeningTalk)
            #expect(talks.count == 1)
            #expect(talks.first?.parameters["discourseID"] == bird1)
            #expect(talks.first?.parameters["completed"] == "true")
            #expect(talks.first?.parameters["starts"] == "1")
            #expect(talks.first?.value == 900)
            #expect(sink.sent.count == 2)
            #expect(service.pendingCounters.isEmpty)
        }

        @Test func oneTalkHeardInPartsIsOneSignal() {
            let (service, sink, _) = makeService()
            service.playbackStarted(bird1, kind: .original, reason: .user, rate: 1)
            service.addListening(seconds: 40)
            service.flushListening(trigger: .background, continuing: true)
            service.addListening(seconds: 40)
            service.playbackStarted(bird1, kind: .translation(source: "en", target: "hi"), reason: .user, rate: 1)
            service.addListening(seconds: 120)
            service.flushListening(trigger: .stopped)
            service.sendSummaryIfDue(trigger: .background)

            let talks = sink.sentNamed(.listeningTalk)
            #expect(talks.count == 2)
            #expect(talks.compactMap(\.value).sorted() == [80, 120])
            #expect(talks.first { $0.parameters["kind"] == "translation" }?.parameters["targetLanguage"] == "hi")
            #expect(talks.first { $0.parameters["kind"] == "original" }?.parameters["starts"] == "1")
        }

        @Test func summariesAreAtLeastTwelveHoursApart() {
            var clock = Date(timeIntervalSince1970: 1_800_000_000)
            let (service, sink, _) = makeService(now: { clock })
            service.sendSummaryIfDue(trigger: .launch)
            #expect(sink.sent.isEmpty)

            service.send(.seriesOpened)
            service.sendSummaryIfDue(trigger: .background)
            service.send(.seriesOpened)
            clock += 11 * 3600
            service.sendSummaryIfDue(trigger: .foreground)
            #expect(sink.sentNamed(.usageSummary).count == 1)

            clock += 2 * 3600
            service.sendSummaryIfDue(trigger: .launch)
            let summaries = sink.sentNamed(.usageSummary)
            #expect(summaries.count == 2)
            #expect(summaries.last?.parameters["Series.opened"] == "1")
        }

        @Test func countedUsageSurvivesARelaunch() {
            let (service, sink, defaults) = makeService()
            service.send(.bookmarkDeleted)
            service.setEnabled(false)
            service.setEnabled(true)
            #expect(service.pendingCounters.isEmpty, "turning usage data off discards what was counted")

            service.send(.bookmarkDeleted)
            let relaunched = TelemetryService(sink: sink, defaults: defaults)
            relaunched.start(enabled: true)
            #expect(sink.sentNamed(.usageSummary).last?.parameters["Bookmark.deleted"] == "1")
        }

        @Test func aSummarySendsAtMostTenTalks() {
            let (service, sink, _) = makeService()
            for number in 1...12 {
                service.playbackStarted("english-A_Bird_on_the_Wing__-\(number)", kind: .original, reason: .user, rate: 1)
                service.addListening(seconds: Double(60 + number))
            }
            service.flushListening(trigger: .stopped)
            service.sendSummaryIfDue(trigger: .background)
            let talks = sink.sentNamed(.listeningTalk)
            #expect(talks.count == TelemetryService.maximumTalksPerSummary)
            #expect(talks.first?.value == 72)
        }

        @Test func carPlayListeningIsCountedWhileConnected() {
            let (service, _, _) = makeService()
            service.playbackStarted(bird1, kind: .original, reason: .user, rate: 1)
            service.addListening(seconds: 30)
            service.setCarPlayActive(true)
            service.addListening(seconds: 120)
            service.setCarPlayActive(false)
            service.addListening(seconds: 30)
            #expect(service.pendingSeconds["CarPlay.listening"] == 120)
        }

        @Test func contextValuesSurviveSettingsUpdates() throws {
            let (service, sink, _) = makeService()
            service.setContextValue("appInstalled", for: "watch")
            service.updateContext(["Settings.smartDelete": "true"])
            let defaultParameters = try #require(sink.defaultParameters)
            let parameters = defaultParameters()
            #expect(parameters["watch"] == "appInstalled")
            #expect(parameters["Settings.smartDelete"] == "true")
        }

        @Test func everyCountedDimensionIsAParameterName() {
            for signal in TelemetrySignal.allCases {
                #expect(!signal.countedDimensions.contains { $0.contains(".") }, "\(signal)")
            }
            #expect(TelemetryParameters.count(0) == "0")
            #expect(TelemetryParameters.count(42) == "42")
            #expect(TelemetryParameters.count(100) == "100+")
        }

        // MARK: Parameters

        @Test func bucketsAreCoarse() {
            let cases: [(Int, String)] = [(0, "0"), (1, "1"), (2, "2-5"), (5, "2-5"), (6, "6-10"), (25, "11-25"),
                                          (26, "26-50"), (100, "51-100"), (101, "100+")]
            for (count, bucket) in cases {
                #expect(TelemetryParameters.bucket(count) == bucket)
            }
        }

        @Test func ratesRoundToTheSliderStep() {
            #expect(TelemetryParameters.rate(1) == "1.00")
            #expect(TelemetryParameters.rate(0.849) == "0.85")
            #expect(TelemetryParameters.rate(1.124) == "1.10")
        }

        @Test func unknownDiscourseKeepsOnlyItsID() {
            #expect(TelemetryParameters.discourse("narration:abc") == ["discourseID": "narration:abc"])
        }

        @Test func settingsContextCoversTheTrackedFeatures() {
            let context = TelemetryParameters.settingsContext(.shared)
            for key in ["deviceFamily", "Settings.noiseReduction", "Settings.noiseReductionMode", "Settings.smartDownload",
                        "Settings.smartDelete", "Settings.dailyAccentShuffle", "Settings.languageFilter"] {
                #expect(context[key] != nil, "missing \(key)")
            }
        }

        @Test func aSettingChangeIsSentByTheSharedService() {
            withSharedTelemetry { sink in
                let settings = UserSettings.shared
                let original = settings.smartDelete
                defer { settings.smartDelete = original }
                settings.smartDelete = !original
                settings.smartDelete = !original

                let changes = sink.named(.settingChanged).filter { $0.parameters["setting"] == "smartDelete" }
                #expect(changes.count == 1)
                #expect(changes.first?.parameters["value"] == TelemetryParameters.flag(!original))
                #expect(sink.defaultParameters?()["Settings.smartDelete"] == TelemetryParameters.flag(!original))
            }
        }

        @Test func turningUsageDataOffStopsTheSharedService() {
            withSharedTelemetry { sink in
                let settings = UserSettings.shared
                defer { settings.shareUsageData = true }
                settings.shareUsageData = false
                #expect(!TelemetryService.shared.isRunning)
                settings.smartDelete.toggle()
                settings.smartDelete.toggle()
                #expect(sink.named(.settingChanged).isEmpty)
                #expect(UserDefaults.standard.bool(forKey: "settings.shareUsageData") == false)
            }
        }
    }
}
