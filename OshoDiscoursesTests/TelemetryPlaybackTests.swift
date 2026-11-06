import AVFoundation
import Foundation
import Testing
@testable import OshoDiscourses

/// Player tests give the player its own telemetry service: they wait on AVPlayer, and
/// another suite may swap the shared service's sink while they are suspended.
extension SharedTelemetrySuites {
    @Suite(.serialized)
    @MainActor
    struct TelemetryPlaybackTests {
        private let bird1 = "english-A_Bird_on_the_Wing__-1"
        private let bird2 = "english-A_Bird_on_the_Wing__-2"
        private let bird3 = "english-A_Bird_on_the_Wing__-3"

        private func makeTelemetry() -> (TelemetryService, RecordingTelemetrySink) {
            let sink = RecordingTelemetrySink()
            let defaults = UserDefaults(suiteName: "TelemetryPlaybackTests.\(UUID())")!
            let service = TelemetryService(
                sink: sink, defaults: defaults, rateDebounce: .milliseconds(50), searchDebounce: .milliseconds(50)
            )
            service.start(enabled: true)
            return (service, sink)
        }

        private func items(_ audio: PlaybackAudioFixture, ids: [String]) throws -> [AudioPlayerService.QueueItem] {
            try ids.map { id in
                let url = audio.directory.appendingPathComponent("\(id).caf")
                try FileManager.default.copyItem(at: audio.url, to: url)
                return AudioPlayerService.QueueItem(id: id, url: url, title: "Talk", series: "Integration")
            }
        }

        // MARK: Listening

        @Test func startReasonsFollowTheEntryPoint() async throws {
            let audio = try PlaybackAudioFixture(seconds: 30)
            defer { audio.remove() }
            let queue = try items(audio, ids: [bird1, bird2, bird3])
            let (telemetry, sink) = makeTelemetry()
            let player = AudioPlayerService(
                settings: nil, connectsToSystem: false,
                originalPlaybackActions: .init(
                    autoPlayNext: true, smartDownload: { _ in }, smartDelete: { _ in }, nextDownloadedItem: { _ in nil }
                ),
                telemetry: telemetry
            )
            defer { player.stop() }

            player.playQueue(items: queue)
            try await waitUntil("the first talk plays") { player.isPlaying && player.currentTrackId == bird1 }
            telemetry.addListening(seconds: 5)

            player.skipToNext()
            try await waitUntil("the next talk plays") { player.isPlaying && player.currentTrackId == bird2 }
            telemetry.addListening(seconds: 5)
            try await waitUntil("its duration is known") { player.duration > 0 }
            player.seek(to: 20)
            // Past the end: the talk finishes and auto-advance opens the third.
            player.skipForward(30)
            try await waitUntil("auto-advance plays") { player.isPlaying && player.currentTrackId == bird3 }
            telemetry.addListening(seconds: 5)

            player.telemetryStartReason = .bookmark
            player.playQueue(items: queue, startIndex: 0, resumeAt: 5)
            #expect(player.telemetryStartReason == nil)
            try await waitUntil("the bookmark plays") { player.isPlaying && player.currentTrackId == bird1 }
            telemetry.addListening(seconds: 5)
            player.stop()

            let segments = sink.named(.listeningSession)
            try #require(segments.count == 4)
            #expect(segments.map { $0.parameters["discourseID"] } == [bird1, bird2, bird3, bird1])
            #expect(segments.map { $0.parameters["startReason"] } == ["user", "next", "autoAdvance", "bookmark"])
            #expect(segments.map { $0.parameters["endTrigger"] } == ["switched", "skippedToEnd", "switched", "stopped"])
            #expect(segments.map { $0.parameters["completed"] } == ["false", "false", "false", "false"])
            #expect(segments[1].parameters["skipsForward"] == "1")
            #expect(segments.allSatisfy { $0.parameters["kind"] == "original" && $0.value == 5 })
        }

        @Test func aTalkPlayedToItsEndSendsOneCompletedSegment() async throws {
            let audio = try PlaybackAudioFixture(seconds: 2)
            defer { audio.remove() }
            let (telemetry, sink) = makeTelemetry()
            let player = AudioPlayerService(settings: nil, connectsToSystem: false, telemetry: telemetry)
            defer { player.stop() }

            player.play(localURL: audio.url, id: bird1, title: "Talk", series: "Integration")
            try await waitUntil("playback starts") { player.isPlaying }
            try await waitUntil("the talk finishes") { player.currentTrackId == nil }
            player.stop()

            let segments = sink.named(.listeningSession)
            #expect(segments.count == 1)
            #expect(segments.first?.parameters["completed"] == "true")
            #expect(segments.first?.parameters["endTrigger"] == "finished")
            #expect(segments.first?.parameters["startReason"] == "user")
        }

        @Test func aRestoredTalkStartsAsRestoredAndAResumeAfterAFlushContinues() async throws {
            let audio = try PlaybackAudioFixture(seconds: 30)
            defer { audio.remove() }
            let queue = try items(audio, ids: [bird1])
            let (telemetry, sink) = makeTelemetry()
            let player = AudioPlayerService(settings: nil, connectsToSystem: false, telemetry: telemetry)
            defer { player.stop() }

            player.restoreQueue(items: queue)
            try await waitUntil("the restored talk is ready") { player.duration > 0 }
            player.resumePlayback()
            try await waitUntil("the first play starts") { player.isPlaying }
            telemetry.addListening(seconds: 4)
            player.skipBackward()
            player.seekWithHistory(to: 20)
            player.setPlaying(false)
            telemetry.flushListening(trigger: .background)

            player.setPlaying(true)
            try await waitUntil("playback resumes") { player.isPlaying }
            telemetry.addListening(seconds: 3)
            player.stop()

            let segments = sink.named(.listeningSession)
            #expect(segments.map { $0.parameters["startReason"] } == ["restored", "continued"])
            #expect(segments.map { $0.parameters["endTrigger"] } == ["background", "stopped"])
            #expect(segments.map(\.value) == [4, 3])
            #expect(segments.first?.parameters["skipsBack"] == "1")
            #expect(segments.first?.parameters["seeks"] == "1")
        }

        @Test func anUnreadableItemSendsAClosedFailureCategory() async throws {
            let audio = try PlaybackAudioFixture(seconds: 1)
            defer { audio.remove() }
            let broken = audio.directory.appendingPathComponent("broken.caf")
            try Data(repeating: 0x5A, count: 4096).write(to: broken)
            let (telemetry, sink) = makeTelemetry()
            let player = AudioPlayerService(settings: nil, connectsToSystem: false, telemetry: telemetry)
            defer { player.stop() }

            player.play(localURL: broken, id: bird1, title: "Talk", series: "Integration")
            try await waitUntil("the failure is sent") { !sink.named(.playbackFailed).isEmpty }

            let failure = try #require(sink.named(.playbackFailed).first)
            #expect(sink.named(.playbackFailed).count == 1)
            #expect(failure.parameters["discourseID"] == bird1)
            #expect(failure.parameters["kind"] == "original")
            #expect(["network", "notFound", "decode", "mediaServices", "unknown"].contains(failure.parameters["category"] ?? ""))
            #expect(sink.named(.listeningSession).isEmpty)
        }

        @Test func playbackFailureCategoriesAreBounded() {
            typealias Player = AudioPlayerService
            #expect(Player.playbackFailureCategory(nil) == "unknown")
            #expect(Player.playbackFailureCategory(URLError(.timedOut)) == "network")
            #expect(Player.playbackFailureCategory(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)) == "notFound")
            let decode = NSError(domain: AVFoundationErrorDomain, code: AVError.Code.decodeFailed.rawValue)
            #expect(Player.playbackFailureCategory(decode) == "decode")
            let wrapped = NSError(domain: "Other", code: 1, userInfo: [NSUnderlyingErrorKey: URLError(.notConnectedToInternet)])
            #expect(Player.playbackFailureCategory(wrapped) == "network")
            #expect(Player.playbackFailureCategory(NSError(domain: "Other", code: 1)) == "unknown")
        }

        @Test func onlyAChangedSpeedIsSent() async throws {
            let (telemetry, sink) = makeTelemetry()
            let player = AudioPlayerService(settings: nil, connectsToSystem: false, telemetry: telemetry)
            player.setRate(1)
            player.setRate(1.5)
            player.setRate(1.5)
            try await Task.sleep(for: .milliseconds(250))
            player.setRate(1.5)
            try await Task.sleep(for: .milliseconds(250))
            #expect(sink.named(.speedChanged).map { $0.parameters["rate"] } == ["1.50"])
        }

        @Test func autosavedListeningIsAddedToTheOpenSegment() {
            withSharedTelemetry { sink in
                let defaults = UserDefaults(suiteName: "TelemetryPlaybackTests.state.\(UUID())")!
                let state = PlaybackStateService(defaults: defaults, recordListeningTime: { _ in }, saveListeningStats: {})
                let player = AudioPlayerService(settings: nil, connectsToSystem: false)
                state.attach(to: player)
                let telemetry = TelemetryService.shared

                telemetry.playbackStarted(bird1, kind: .original, reason: .user, rate: 1)
                player.currentTrackId = bird1
                player.isPlaying = true
                for time in [10.0, 18, 400, 405] {
                    player.currentTime = time
                    state.saveCurrentPosition()
                }
                telemetry.flushListening(trigger: .stopped)

                // A translation's seconds count too, though its position is kept elsewhere.
                telemetry.playbackStarted(bird1, kind: .translation(source: "en", target: "hi"), reason: .user, rate: 1)
                player.currentTrackId = AudioPlayerService.narrationTrackID(for: "doc")
                for time in [30.0, 36] {
                    player.currentTime = time
                    state.saveCurrentPosition()
                }
                telemetry.flushListening(trigger: .stopped)

                // The jump from 18 to 400 is a seek, not listening.
                #expect(sink.named(.listeningSession).map(\.value) == [13, 6])
            }
        }

        // MARK: Downloads

        @Test func downloadOutcomesCarryOriginSourceAndCategory() throws {
            try withSharedTelemetry { sink in
                let downloads = DownloadService()
                let telemetry = TelemetryService.shared
                telemetry.noteDownloadOrigin(bird1, .smartDownload)
                downloads.reportDownloadCompleted(bird1, source: .oshoworld, fallback: true)
                downloads.reportDownloadCompleted(bird2, source: nil, fallback: false)
                telemetry.noteDownloadOrigin(bird2, .user)
                downloads.reportDownloadFailed(bird2, error: DownloadService.DownloadError.serverError(503))
                downloads.reportDownloadFailed(bird3, error: URLError(.timedOut))
                telemetry.noteDownloadOrigin(bird1, .downloadAll)
                downloads.reportDownloadFailed(bird1, error: CancellationError())
                #expect(telemetry.takeDownloadOrigin(bird1) == .unknown, "a cancellation still consumes the origin")

                let completed = sink.named(.downloadCompleted).map(\.parameters)
                try #require(completed.count == 2)
                #expect(completed[0]["discourseID"] == bird1)
                #expect(completed[0]["seriesID"] == "english-A_Bird_on_the_Wing__")
                #expect(completed[0]["origin"] == "smartDownload")
                #expect(completed[0]["source"] == "oshoworld")
                #expect(completed[0]["fallback"] == "true")
                #expect(completed[1]["origin"] == "unknown")
                #expect(completed[1]["source"] == "unknown")
                #expect(completed[1]["fallback"] == "false")

                let failed = sink.named(.downloadFailed).map(\.parameters)
                #expect(failed.map { $0["category"] } == ["serverError", "transport"])
                #expect(failed.map { $0["origin"] } == ["user", "unknown"])
            }
        }

        @Test func downloadFailureCategoriesAreCaseNames() {
            typealias Failure = DownloadService.DownloadError
            #expect(DownloadService.failureCategory(CancellationError()) == nil)
            #expect(DownloadService.failureCategory(URLError(.cancelled)) == nil)
            #expect(DownloadService.failureCategory(Failure.wifiOnly) == "wifiOnly")
            #expect(DownloadService.failureCategory(Failure.serverError(500)) == "serverError")
            #expect(DownloadService.failureCategory(Failure.stalled) == "stalled")
            #expect(DownloadService.failureCategory(URLError(.badURL)) == "transport")
        }

        @Test func deletesAreSentWithTheirReasonAndBatchesOnce() async throws {
            let series = try #require(Catalog.allSeries.last)
            let discourses = Array(Catalog.discourses(for: series).prefix(4))
            try #require(discourses.count == 4)
            let downloads = DownloadService()
            defer { for discourse in discourses { try? downloads.deleteDownload(discourseID: discourse.id) } }

            try await withSharedTelemetry { sink in
                for discourse in discourses {
                    let file = downloads.fileURL(for: discourse)
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(repeating: 1, count: 64).write(to: file)
                }
                // A file already on disk is recorded, not downloaded: no completion, and no stale origin.
                TelemetryService.shared.noteDownloadOrigin(discourses[0].id, .user)
                for discourse in discourses { _ = try await downloads.download(discourse) }
                #expect(sink.named(.downloadCompleted).isEmpty)
                #expect(TelemetryService.shared.takeDownloadOrigin(discourses[0].id) == .unknown)

                try downloads.deleteDownload(discourseID: discourses[0].id)
                try downloads.deleteDownload(discourseID: discourses[1].id, reason: .smartDelete)
                try downloads.deleteDownload(discourseID: discourses[0].id)
                downloads.deleteDownloads(ids: [discourses[2].id, discourses[3].id, "not-downloaded"])
                downloads.deleteDownloads(ids: ["not-downloaded"])

                let deleted = sink.named(.downloadDeleted)
                try #require(deleted.count == 3)
                #expect(deleted[0].parameters["discourseID"] == discourses[0].id)
                #expect(deleted[0].parameters["reason"] == "user")
                #expect(deleted[1].parameters["reason"] == "smartDelete")
                #expect(deleted[2].parameters["scope"] == "selection")
                #expect(deleted[2].parameters["count"] == "2-5")
                #expect(deleted[2].parameters["seriesID"] == series.id)
                #expect(deleted[2].parameters["discourseID"] == nil)
                #expect(deleted[2].value == 2)
            }
        }

        // MARK: Sleep timer

        @Test func sleepTimerSendsItsOptionAndOnlyListenerCancels() {
            withSharedTelemetry { sink in
                let timer = SleepTimerService.shared
                timer.cancel()
                defer { timer.cancel() }
                timer.start(minutes: 30)
                timer.cancelByListener()
                timer.startUntilEndOfDiscourse()
                timer.cancel()
                timer.cancelByListener()
                timer.start(minutes: 5)
                timer.startUntilEndOfDiscourse()
                timer.cancelByListener()

                #expect(sink.named(.sleepTimerStarted).map { $0.parameters["option"] } == ["30", "endOfDiscourse", "5", "endOfDiscourse"])
                #expect(sink.named(.sleepTimerCancelled).map { $0.parameters["option"] } == ["30", "endOfDiscourse"])
            }
        }

        // MARK: CarPlay and Watch

        #if canImport(CarPlay) && !targetEnvironment(macCatalyst)
        @Test func aCarPlayConnectionIsSentOnce() {
            withSharedTelemetry { sink in
                let session = CarPlayFixture.session(FakeCarPlaySource(), interface: CarPlayTestInterface())
                session.disconnect()
                let connected = sink.named(.carPlayConnected)
                #expect(connected.count == 1)
                #expect(["tabs", "menu"].contains(connected.first?.parameters["layout"] ?? ""))
            }
        }
        #endif

        #if canImport(WatchConnectivity) && !targetEnvironment(macCatalyst)
        @Test func everyWatchCommandButSnapshotsIsCounted() {
            withSharedTelemetry { sink in
                let surface = FakeWatchSurface()
                surface.currentDiscourseID = "a"
                let handler = CompanionRequestHandler(surface: surface, transfers: nil)
                let transport: [CompanionAction] = [
                    .snapshot, .setPlaying(true), .skipForward, .skipBackward, .nextDiscourse, .previousDiscourse, .setRate(1.25),
                ]
                for action in transport { _ = handler.handle(WatchFixture.request(action, expected: "a")) }
                _ = handler.handle(WatchFixture.request(.browse(.continueListening)))
                let play = WatchFixture.request(.playItem(rowID: "d:abc"))
                _ = handler.handle(play)
                _ = handler.handle(play)
                _ = handler.handle(WatchFixture.request(.sendToWatch(discourseID: bird1)))

                let commands = sink.named(.watchCommand).compactMap { $0.parameters["command"] }
                #expect(commands == [
                    "setPlaying", "skipForward", "skipBackward", "nextDiscourse", "previousDiscourse", "setRate",
                    "browse", "playItem", "sendToWatch",
                ])
                #expect(sink.named(.watchCommand).last?.parameters["outcome"] == "transfer.unavailable")
                #expect(TelemetryService.shared.pendingCounters["Watch.command.command.skipForward"] == 1)
                #expect(sink.sent.isEmpty)
            }
        }

        @Test func offlineWatchListeningCountsOnlyForwardProgress() {
            withSharedTelemetry { sink in
                WatchPositionMerger.reportOfflineListening(bird1, from: 600, to: 1500, finished: false)
                WatchPositionMerger.reportOfflineListening(bird1, from: 1500, to: 200, finished: false)
                WatchPositionMerger.reportOfflineListening(bird1, from: 0, to: 6 * 60 * 60, finished: true)

                #expect(sink.named(.watchOfflineListening).map(\.value) == [900, 0, 0])
                #expect(sink.named(.watchOfflineListening).last?.parameters["finished"] == "true")
                #expect(TelemetryService.shared.pendingSeconds["Watch.offlineListening"] == 900)
                #expect(TelemetryService.shared.pendingCounters["Watch.offlineListening"] == 3)
            }
        }

        @Test func watchTransfersSendTheirOutcome() {
            withSharedTelemetry { sink in
                let transfers = WatchTransferService(
                    sink: FakeWatchTransport(), library: FakeTransferLibrary(),
                    defaults: WatchFixture.defaults(), stagingDirectory: WatchFixture.tempDirectory()
                )
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("elsewhere.mp3")
                transfers.transferFinished(discourseID: bird1, fileURL: file, succeeded: true)
                transfers.transferFinished(discourseID: bird2, fileURL: file, succeeded: false)
                transfers.transferFinished(discourseID: nil, fileURL: file, succeeded: true)

                let sent = sink.named(.watchTransfer).map(\.parameters)
                #expect(sent.map { $0["outcome"] } == ["completed", "failed"])
                #expect(sent.map { $0["discourseID"] } == [bird1, bird2])
            }
        }
        #endif

        private func waitUntil(
            _ message: String,
            timeout: Duration = .seconds(15),
            _ condition: @MainActor () -> Bool
        ) async throws {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while !condition(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            try #require(condition(), "Timed out: \(message)")
        }
    }
}
