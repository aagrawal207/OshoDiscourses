import AVFoundation
import Foundation
import Testing
import UIKit
@testable import OshoDiscourses

/// Cold-launch restore of a translated narration: the same row Home shows first,
/// paused at its own position, with nothing claimed or written until the first play.
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct TranslationRestoreTests {
    @Test(arguments: [true, false])
    func homeAndRestorePickTheSameRow(translationIsNewer: Bool) async throws {
        let fixture = try await TranslationRestoreFixture()
        defer { fixture.remove() }
        let state = fixture.makePlaybackState()
        let recording = fixture.notDownloaded.id
        state.savePosition(discourseId: recording, position: 30, duration: 600)
        state.recordPlay(discourseId: recording)
        let playedAt = Date().addingTimeInterval(translationIsNewer ? 60 : -3600)
        fixture.narrations.savePosition(documentID: fixture.spanish.id, position: 12)
        fixture.narrations.recordPlay(documentID: fixture.spanish.id, at: playedAt)

        // Home builds its rows from this list; restore takes the first row it can load.
        let rows = ContinueListening.rows(
            playbackState: state, narrations: fixture.narrations,
            isDownloaded: { $0 == recording }, currentTrackID: nil
        )
        let translation = ContinueListening.Row.translation(fixture.spanish)
        #expect(rows == (translationIsNewer ? [translation, .recording(recording)] : [.recording(recording), translation]))
        let candidates = ContinueListening.restoreCandidates(
            rows, hasFile: { _ in true }, hasNarrationAudio: fixture.preview.hasPlayableAudio
        )
        #expect(candidates.first == rows.first)

        // The launcher sees the real downloads, where this recording is absent, so the translation returns either way.
        let player = fixture.makePlayer()
        defer { player.service.stop() }
        fixture.attach(state, to: player.service)
        let restored = await fixture.makeLauncher(player.service).restoreLastSession(from: state)
        #expect(restored == translation.trackID)
        #expect(player.service.currentNarration == fixture.spanish)
    }

    @Test func restoredTranslationWaitsPausedWithoutClaimingOrWriting() async throws {
        let fixture = try await TranslationRestoreFixture()
        defer { fixture.remove() }
        let state = fixture.makePlaybackState()
        let player = fixture.makePlayer()
        let service = player.service
        defer { service.stop() }
        fixture.attach(state, to: service)
        state.savePosition(
            discourseId: fixture.spanish.discourseID, position: 30, duration: 600,
            savedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        state.recordPlay(discourseId: fixture.spanish.discourseID)
        fixture.narrations.savePosition(documentID: fixture.spanish.id, position: 12)
        fixture.narrations.recordPlay(documentID: fixture.spanish.id, at: Date().addingTimeInterval(-60))
        let original = state.exportCloudSnapshot()
        let recent = state.recentlyPlayed
        let narrationPlays = fixture.narrations.recentPlays


        let restored = await fixture.makeLauncher(service).restoreLastSession(from: state)
        #expect(restored == AudioPlayerService.narrationTrackID(for: fixture.spanish.id))
        #expect(service.currentNarration == fixture.spanish)
        #expect(service.currentDiscourseID == fixture.spanish.discourseID)
        #expect(service.currentTitle == fixture.source.displayTitle)
        #expect(service.currentSeries == fixture.source.seriesName)
        #expect(service.currentTime == 12, "the mini-player shows the saved position at once")
        #expect(service.duration == fixture.spanish.duration)
        #expect(!service.isPlaying)

        try await waitUntil("the translation is ready at its saved position") {
            player.native.currentItem?.status == .readyToPlay
                && abs(player.native.currentTime().seconds - 12) < 0.5
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!service.isPlaying)
        #expect(player.native.rate == 0)
        #expect(player.native.currentItem?.audioMix == nil)
        #expect(service.audioProcessingStatus == .synthesizedNarration)

        // Launch makes the scene active; that must not take audio from another app.
        service.handleForegroundReturn()
        #expect(player.activations.value == 0)
        #expect(!service.hasClaimedAudioSession)
        #expect(service.playSession == nil)
        #expect(!fixture.narrations.isPreparing)
        #expect(fixture.narrations.preparingDocumentID == nil)
        #expect(fixture.narrations.preparationOwner == nil)
        // The Watch and CarPlay read a loaded translation as "translation playing" and offer no recording controls.
        #expect(service.isPlayingNarration)
        #expect(fixture.makeLibrary(state: state, player: service).nowPlaying() == nil)

        state.saveCurrentPosition()
        #expect(state.exportCloudSnapshot() == original)
        #expect(state.recentlyPlayed == recent)
        #expect(state.completedDiscourseIDs.isEmpty)
        #expect(fixture.defaults.object(forKey: "playbackPosition_" + service.currentTrackId!) == nil)
        #expect(fixture.narrations.recentPlays == narrationPlays)
        #expect(abs(fixture.narrations.position(for: fixture.spanish.id) - 12) < 0.5)

        service.togglePlayPause()
        try await waitUntil("playback resumes from the saved position") {
            service.isPlaying && player.native.timeControlStatus == .playing
        }
        #expect(player.activations.value == 1)
        #expect(service.hasClaimedAudioSession)
        let clock = player.native.currentTime().seconds
        #expect(clock >= 11.5 && clock < 15)
        #expect(fixture.narrations.recentPlays[fixture.spanish.id]! > narrationPlays[fixture.spanish.id]!)
        #expect(state.exportCloudSnapshot() == original)
        #expect(state.recentlyPlayed == recent)
    }

    @Test func partialTranslationRestoresWithinItsFinishedPassages() async throws {
        let fixture = try await TranslationRestoreFixture()
        defer { fixture.remove() }
        let state = fixture.makePlaybackState()
        let player = fixture.makePlayer()
        let service = player.service
        defer { service.stop() }
        fixture.attach(state, to: service)
        let prefix = try #require(fixture.narrations.playablePrefix(of: fixture.partial.id))
        #expect(!fixture.partial.isComplete && prefix.document.segments.count == 1)
        fixture.narrations.savePosition(documentID: fixture.partial.id, position: 4)
        fixture.narrations.recordPlay(documentID: fixture.partial.id)

        let restored = await fixture.makeLauncher(service).restoreLastSession(from: state)
        #expect(restored == AudioPlayerService.narrationTrackID(for: fixture.partial.id))
        #expect(service.isPlayingNarrationPreview)
        #expect(service.currentNarration == prefix.document)
        #expect(service.duration == prefix.document.duration)
        #expect(service.currentTime == 4)
        // The end of the finished passages hands over to the preview controller, as when it plays.
        #expect(service.onNarrationPreviewEnd != nil)
        try await waitUntil("the finished passages are ready at the saved position") {
            player.native.currentItem?.status == .readyToPlay
                && abs(player.native.currentTime().seconds - 4) < 0.5
        }
        #expect(!service.isPlaying)
        #expect(player.activations.value == 0)
        #expect(!fixture.narrations.isPreparing)

        service.setPlaying(true)
        try await waitUntil("the finished passages play") { service.isPlaying }
        #expect(player.activations.value == 1)
        #expect(!fixture.narrations.isPreparing, "playing never starts translation")
    }

    @Test func aTranslationWhoseAudioIsGoneFallsBackToTheNextRow() async throws {
        let fixture = try await TranslationRestoreFixture()
        defer { fixture.remove() }
        let state = fixture.makePlaybackState()
        let player = fixture.makePlayer()
        defer { player.service.stop() }
        fixture.attach(state, to: player.service)
        fixture.narrations.savePosition(documentID: fixture.spanish.id, position: 12)
        fixture.narrations.recordPlay(documentID: fixture.spanish.id, at: Date().addingTimeInterval(120))
        fixture.narrations.savePosition(documentID: fixture.french.id, position: 7)
        fixture.narrations.recordPlay(documentID: fixture.french.id, at: Date().addingTimeInterval(60))
        try fixture.removeSavedAudio(of: fixture.spanish)

        let rows = ContinueListening.rows(
            playbackState: state, narrations: fixture.narrations, isDownloaded: { _ in false }, currentTrackID: nil
        )
        #expect(rows == [.translation(fixture.spanish), .translation(fixture.french)])
        #expect(!fixture.preview.hasPlayableAudio(fixture.spanish))

        // The fixture voices are not installed; saved audio plays without its voice.
        let restored = await fixture.makeLauncher(player.service).restoreLastSession(from: state)
        #expect(restored == AudioPlayerService.narrationTrackID(for: fixture.french.id))
        #expect(player.service.currentNarration == fixture.french)
        #expect(player.service.currentTime == 7)
        #expect(player.service.narrationPlaybackFailure == nil)
    }

    @Test func restoreLeavesAnAlreadyLoadedTalkAlone() async throws {
        let fixture = try await TranslationRestoreFixture()
        defer { fixture.remove() }
        let state = fixture.makePlaybackState()
        let player = fixture.makePlayer()
        defer { player.service.stop() }
        fixture.attach(state, to: player.service)
        fixture.narrations.savePosition(documentID: fixture.spanish.id, position: 12)
        fixture.narrations.recordPlay(documentID: fixture.spanish.id)
        player.service.playNarration(fixture.french, url: try #require(fixture.narrations.audioURL(for: fixture.french)))

        #expect(await fixture.makeLauncher(player.service).restoreLastSession(from: state) == nil)
        #expect(player.service.currentNarration == fixture.french)
    }

    @Test func leavingTheForegroundSavesTheTranslationsLiveClock() async throws {
        let fixture = try await TranslationRestoreFixture()
        defer { fixture.remove() }
        let state = fixture.makePlaybackState()
        let player = fixture.makePlayer()
        defer { player.service.stop() }
        fixture.attach(state, to: player.service)
        let center = NotificationCenter()
        state.saveWhenLeavingForeground(center: center)
        let original = state.exportCloudSnapshot()
        player.service.playNarration(fixture.spanish, url: try #require(fixture.narrations.audioURL(for: fixture.spanish)))
        try await waitUntil("playing past 2 s") {
            player.service.isPlaying && player.native.currentTime().seconds > 2.2
        }

        center.post(name: UIApplication.willResignActiveNotification, object: nil)
        let live = player.native.currentTime().seconds
        #expect(abs(fixture.narrations.position(for: fixture.spanish.id) - live) < 0.1)
        #expect(state.getPosition(discourseId: player.service.currentTrackId!) == 0)
        #expect(state.exportCloudSnapshot() == original)
    }

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

/// Two complete translations and one with only its first passage, loaded the way a
/// cold launch loads them, in isolated defaults and storage.
@MainActor
private struct TranslationRestoreFixture {
    struct Player {
        let service: AudioPlayerService
        let native: AVPlayer
        let activations: Counter
    }

    @MainActor
    final class Counter {
        var value = 0
    }

    let suite: String
    let directory: URL
    let cacheURL: URL
    let defaults: UserDefaults
    let source: CatalogDiscourse
    let notDownloaded: CatalogDiscourse
    let spanish: NarrationDocument
    let french: NarrationDocument
    let partial: NarrationDocument
    let narrations: NarrationService
    let preview: NarrationPreviewPlayback

    init() async throws {
        suite = "TranslationRestore-" + UUID().uuidString
        defaults = try #require(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        cacheURL = directory.appendingPathComponent("narrations", isDirectory: true)
        let series = try #require(Catalog.englishSeries.first)
        source = try #require(Catalog.discourses(for: series).first)
        let downloads = DownloadService()
        notDownloaded = try #require(Catalog.allDiscourses().first { !downloads.isDownloaded($0.id) })
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let audio = directory.appendingPathComponent("generated.m4a")
            try Self.writeAudio(to: audio, seconds: 30)
            let renderer = try RestoreFixtureRenderer(audioURL: audio)
            let preparing = NarrationService(directory: cacheURL, defaults: defaults)
            let oneParagraph = Transcript(
                discourseID: source.id, sourceID: "restore-test", fetchedAt: Date(timeIntervalSince1970: 1),
                paragraphs: [.init(index: 0, text: "A prepared local narration.", isEmphasis: false)]
            )
            let spanishDocument = try await preparing.prepare(
                transcript: oneParagraph, selection: Self.selection("es"), translate: { $0 }, renderer: renderer
            )
            let frenchDocument = try await preparing.prepare(
                transcript: oneParagraph, selection: Self.selection("fr"), translate: { $0 }, renderer: renderer
            )
            let partialID = try await Self.preparePartial(
                source: source, cacheURL: cacheURL, renderer: renderer
            )

            let loaded = NarrationService(directory: cacheURL, defaults: defaults)
            await loaded.load()
            spanish = try #require(loaded.documents.first { $0.id == spanishDocument.id })
            french = try #require(loaded.documents.first { $0.id == frenchDocument.id })
            partial = try #require(loaded.documents.first { $0.id == partialID })
            narrations = loaded
            preview = NarrationPreviewPlayback(narrations: loaded)
        } catch {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func makePlaybackState() -> PlaybackStateService {
        PlaybackStateService(defaults: defaults, recordListeningTime: { _ in }, saveListeningStats: {})
    }

    func makePlayer() -> Player {
        let native = AVPlayer()
        native.isMuted = true
        let activations = Counter()
        let service = AudioPlayerService(
            settings: nil, connectsToSystem: false, narrationService: narrations,
            makePlayer: { native }, activateAudioSession: { activations.value += 1 }
        )
        return Player(service: service, native: native, activations: activations)
    }

    func makeLauncher(_ player: AudioPlayerService) -> PlaybackLauncher {
        PlaybackLauncher(
            player: player, downloads: DownloadService(), bookmarks: .shared,
            narrations: narrations, narrationPlayback: preview
        )
    }

    func makeLibrary(state: PlaybackStateService, player: AudioPlayerService) -> CompanionLibrary {
        CompanionLibrary(downloads: DownloadService(), playbackState: state, bookmarks: .shared, player: player)
    }

    func attach(_ state: PlaybackStateService, to service: AudioPlayerService) {
        service.playbackStateService = state
        state.attach(to: service)
    }

    func removeSavedAudio(of document: NarrationDocument) throws {
        try FileManager.default.removeItem(at: cacheURL.appendingPathComponent(document.id, isDirectory: true))
    }

    func remove() {
        preview.stopWaiting()
        narrations.cancel()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    private static func selection(_ language: String) -> NarrationSelection {
        NarrationSelection(
            sourceLanguage: "en", targetLanguage: language,
            voice: NarrationVoice(id: "test-\(language)", name: "Test voice", language: language, quality: 1)
        )
    }

    /// Saves the first of two passages and stops, as a run iOS ended part-way leaves it.
    private static func preparePartial(
        source: CatalogDiscourse, cacheURL: URL, renderer: RestoreFixtureRenderer
    ) async throws -> String {
        let cache = NarrationCache(directory: cacheURL)
        let job = NarrationCache.Job()
        let transcript = Transcript(
            discourseID: source.id, sourceID: "restore-partial", fetchedAt: Date(timeIntervalSince1970: 1),
            paragraphs: [
                .init(index: 0, text: "First source passage.", isEmphasis: false),
                .init(index: 1, text: "Second source passage.", isEmphasis: false),
            ]
        )
        let plan = try NarrationCache.Plan(transcript: transcript, selection: selection("de"))
        _ = try await cache.start(plan: plan, job: job)
        let output = try await cache.outputURL(segment: 0, job: job)
        let duration = try await renderer.render(text: "Erster Abschnitt.", voiceID: "test-de", to: output)
        _ = try await cache.checkpoint(index: 0, text: "Erster Abschnitt.", duration: duration, job: job)
        job.cancel()
        await cache.discardStaging(job: job)
        return plan.document.id
    }

    private static func writeAudio(to url: URL, seconds: TimeInterval) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000,
        ])
        defer { file.close() }
        let block = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        let samples = try #require(block.floatChannelData)[0]
        let frames = Int(seconds * format.sampleRate)
        var offset = 0
        while offset < frames {
            let count = min(4096, frames - offset)
            block.frameLength = AVAudioFrameCount(count)
            for index in 0..<count {
                samples[index] = Float(0.01 * sin(2 * .pi * 170 * Double(offset + index) / format.sampleRate))
            }
            try file.write(from: block)
            offset += count
        }
    }
}

@MainActor
private final class RestoreFixtureRenderer: NarrationSpeechRendering {
    private let audioURL: URL
    private let duration: TimeInterval

    init(audioURL: URL) throws {
        self.audioURL = audioURL
        let file = try AVAudioFile(forReading: audioURL)
        defer { file.close() }
        duration = Double(file.length) / file.processingFormat.sampleRate
    }

    func render(text: String, voiceID: String, to outputURL: URL) async throws -> TimeInterval {
        try FileManager.default.copyItem(at: audioURL, to: outputURL)
        return duration
    }

    func assemble(segments: [URL], to outputURL: URL) async throws -> TimeInterval {
        try FileManager.default.copyItem(at: try #require(segments.first), to: outputURL)
        return duration
    }

    func cancel() {}
}
