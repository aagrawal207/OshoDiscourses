#if TRANSLATED_NARRATION
import AVFoundation
import Foundation
import Testing
@testable import OshoDiscourses

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NarrationAutoplayIntentTests {
    @Test func delayedPrefixStartsWhenPlaybackIntentIsUnchanged() async throws {
        try await withFixture { fixture in
            let generation = fixture.player.playbackGeneration
            let intent = fixture.player.playbackIntentGeneration
            try await fixture.startDelayedPreview()
            #expect(fixture.player.currentNarration == nil)
            #expect(!fixture.player.isPlaying)
            #expect(fixture.player.playbackGeneration == generation)
            #expect(fixture.player.playbackIntentGeneration == intent)

            fixture.timeline.release()
            try await autoplayEventually("the unchanged preview to start") {
                fixture.player.isPlaying && fixture.player.isPlayingNarrationPreview
            }
            #expect(!fixture.preview.isLoading)
            #expect(fixture.preview.failureMessage == nil)
            #expect(fixture.player.currentNarration?.id == fixture.document.id)
            #expect(fixture.player.currentTrackId == AudioPlayerService.narrationTrackID(for: fixture.document.id))
            #expect(fixture.player.playbackGeneration != generation)
            #expect(fixture.timeline.requests == [fixture.segmentURLs])
        }
    }

    @Test(arguments: [false, true])
    func explicitPauseInvalidatesDelayedPrefixEvenWithoutPlayingAudio(hasOriginal: Bool) async throws {
        try await withFixture { fixture in
            if hasOriginal { try await fixture.playOriginal() }
            try await fixture.startDelayedPreview()
            let item = fixture.native.currentItem
            let generation = fixture.player.playbackGeneration
            let intent = fixture.player.playbackIntentGeneration

            fixture.player.setPlaying(false)
            #expect(!fixture.player.isPlaying)
            #expect(fixture.player.playbackIntentGeneration != intent)
            #expect(fixture.player.playbackGeneration == generation)
            try await fixture.finishDelayedPreview()

            #expect(fixture.player.currentNarration == nil)
            #expect(fixture.native.currentItem === item)
            #expect(fixture.player.currentTrackId == (hasOriginal ? fixture.source.id : nil))
            #expect(fixture.player.playbackGeneration == generation)
            #expect(!fixture.player.isPlaying)
            #expect(fixture.narrations.position(for: fixture.document.id) == 0)
        }
    }

    @Test(arguments: [false, true])
    func seekingInvalidatesDelayedPrefixWithoutReplacingTheCurrentItem(hasOriginal: Bool) async throws {
        try await withFixture { fixture in
            if hasOriginal {
                try await fixture.playOriginal()
                fixture.player.setPlaying(false)
            }
            try await fixture.startDelayedPreview()
            let item = fixture.native.currentItem
            let generation = fixture.player.playbackGeneration
            let intent = fixture.player.playbackIntentGeneration

            fixture.player.seek(to: 2)
            #expect(fixture.player.playbackIntentGeneration != intent)
            #expect(fixture.player.playbackGeneration == generation)
            try await fixture.finishDelayedPreview()

            #expect(fixture.player.currentNarration == nil)
            #expect(fixture.native.currentItem === item)
            #expect(fixture.player.currentTrackId == (hasOriginal ? fixture.source.id : nil))
            #expect(fixture.player.playbackGeneration == generation)
            #expect(!fixture.player.isPlaying)
            if hasOriginal { #expect(abs(fixture.player.currentTime - 2) < 0.1) }
            #expect(fixture.narrations.position(for: fixture.document.id) == 0)
        }
    }

    @Test func choosingATrackWhileThePrefixBuildsKeepsTheChosenTrack() async throws {
        try await withFixture { fixture in
            try await fixture.startDelayedPreview()
            let generation = fixture.player.playbackGeneration
            let intent = fixture.player.playbackIntentGeneration
            try await fixture.playOriginal()
            let item = try #require(fixture.native.currentItem)
            let chosenGeneration = fixture.player.playbackGeneration
            #expect(chosenGeneration != generation)
            #expect(fixture.player.playbackIntentGeneration == intent)

            try await fixture.finishDelayedPreview()
            #expect(fixture.native.currentItem === item)
            #expect(fixture.player.currentTrackId == fixture.source.id)
            #expect(fixture.player.currentNarration == nil)
            #expect(fixture.player.playbackGeneration == chosenGeneration)
            #expect(fixture.player.isPlaying)
            #expect(fixture.narrations.position(for: fixture.document.id) == 0)
        }
    }

    @Test(arguments: [false, true])
    func playPauseToggleInvalidatesThePendingPrefix(hasOriginal: Bool) async throws {
        try await withFixture { fixture in
            if hasOriginal { try await fixture.playOriginal() }
            try await fixture.startDelayedPreview()
            let item = fixture.native.currentItem
            let generation = fixture.player.playbackGeneration
            let intent = fixture.player.playbackIntentGeneration

            fixture.player.togglePlayPause()
            #expect(fixture.player.playbackIntentGeneration != intent)
            try await fixture.finishDelayedPreview()

            #expect(!fixture.player.isPlaying)
            #expect(fixture.player.currentNarration == nil)
            #expect(fixture.native.currentItem === item)
            #expect(fixture.player.playbackGeneration == generation)
        }
    }

    @Test func voiceAuditionPausesPendingPlaybackEvenWhenNoAudioIsPlaying() async throws {
        try await withFixture { fixture in
            try await fixture.startDelayedPreview()
            #expect(!fixture.player.isPlaying)
            #expect(fixture.native.currentItem == nil)
            let generation = fixture.player.playbackGeneration
            let intent = fixture.player.playbackIntentGeneration
            let speaker = AutoplayVoiceSpeaker()
            let audition = NarrationVoicePreview(speaker: speaker)
            defer { audition.stop() }
            var pauseCalls = 0

            audition.play(
                voice: fixture.document.selection.voice, sampleText: "Un court extrait.",
                pace: .natural, ownerID: UUID()
            ) {
                pauseCalls += 1
                fixture.player.setPlaying(false)
            }
            #expect(pauseCalls == 1)
            #expect(speaker.spokenVoiceID == fixture.document.selection.voice.id)
            #expect(audition.activeVoiceID == fixture.document.selection.voice.id)
            #expect(fixture.player.playbackIntentGeneration != intent)
            #expect(fixture.player.playbackGeneration == generation)

            try await fixture.finishDelayedPreview()
            #expect(fixture.player.currentNarration == nil)
            #expect(fixture.native.currentItem == nil)
            #expect(!fixture.player.isPlaying)
            #expect(fixture.player.playbackGeneration == generation)

            speaker.finish()
            #expect(audition.activeVoiceID == nil)
            #expect(!fixture.player.isPlaying)
            #expect(fixture.player.currentNarration == nil)
        }
    }

    private func withFixture(_ body: @MainActor (AutoplayIntentFixture) async throws -> Void) async throws {
        let fixture = try await AutoplayIntentFixture()
        defer { fixture.remove() }
        try await body(fixture)
    }
}

@MainActor
private final class AutoplayIntentFixture {
    let suite: String
    let directory: URL
    let defaults: UserDefaults
    let source: CatalogDiscourse
    let audioURL: URL
    let narrations: NarrationService
    let document: NarrationDocument
    let segmentURLs: [URL]
    let native: AVPlayer
    let player: AudioPlayerService
    let timeline: AutoplayTimelineGate
    let preview: NarrationPreviewPlayback

    init() async throws {
        let suite = "NarrationAutoplayIntentTests.\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let defaults = try #require(UserDefaults(suiteName: suite))
        let cacheURL = directory.appendingPathComponent("narrations", isDirectory: true)
        let cache = NarrationCache(directory: cacheURL)
        let job = NarrationCache.Job()
        self.suite = suite
        self.directory = directory
        self.defaults = defaults

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let series = try #require(Catalog.englishSeries.first)
            let source = try #require(Catalog.discourses(for: series).first)
            let audioURL = directory.appendingPathComponent("fixture.m4a")
            try Self.writeAudio(to: audioURL)
            let selection = NarrationSelection(
                sourceLanguage: "en", targetLanguage: "fr",
                voice: NarrationVoice(id: "test-fr", name: "Test French", language: "fr-FR", quality: 1),
                pace: .natural
            )
            let transcript = Transcript(
                discourseID: source.id, sourceID: "autoplay-fixture", fetchedAt: Date(timeIntervalSince1970: 1),
                paragraphs: [
                    .init(index: 0, text: "First source passage.", isEmphasis: false),
                    .init(index: 1, text: "Second source passage.", isEmphasis: false),
                ]
            )
            let plan = try NarrationCache.Plan(transcript: transcript, selection: selection)
            _ = try await cache.start(plan: plan, job: job)
            let output = try await cache.outputURL(segment: 0, job: job)
            let renderer = try AutoplayFixtureRenderer(audioURL: audioURL)
            let duration = try await renderer.render(text: "Premier passage.", voiceID: selection.voice.id, to: output)
            _ = try await cache.checkpoint(index: 0, text: "Premier passage.", duration: duration, job: job)
            job.cancel()
            await cache.discardStaging(job: job)

            let narrations = NarrationService(directory: cacheURL, defaults: defaults)
            await narrations.load()
            let prefix = try #require(narrations.playablePrefix(of: plan.document.id))
            #expect(prefix.document.segments.count == 1)
            #expect(!prefix.document.isComplete)
            let composition = try await NarrationPreviewPlayback.timeline(joining: prefix.segmentURLs)
            let timeline = AutoplayTimelineGate(composition: composition)
            let native = AVPlayer()
            native.isMuted = true
            let player = AudioPlayerService(
                settings: nil, connectsToSystem: false, narrationService: narrations, makePlayer: { native }
            )
            self.source = source
            self.audioURL = audioURL
            self.narrations = narrations
            self.document = prefix.document
            self.segmentURLs = prefix.segmentURLs
            self.native = native
            self.player = player
            self.timeline = timeline
            self.preview = NarrationPreviewPlayback(narrations: narrations, makeTimeline: { await timeline.build($0) })
        } catch {
            job.cancel()
            await cache.discardStaging(job: job)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func startDelayedPreview() async throws {
        preview.play(documentID: document.id, player: player)
        try await autoplayEventually("the prefix build to suspend") { self.timeline.requests.count == 1 }
        #expect(preview.isLoading)
        #expect(timeline.completedBuilds == 0)
    }

    func finishDelayedPreview() async throws {
        timeline.release()
        try await autoplayEventually("the delayed prefix to settle") { !self.preview.isLoading }
        #expect(timeline.completedBuilds == 1)
        #expect(preview.failureMessage == nil)
        #expect(player.narrationPlaybackFailure == nil)
    }

    func playOriginal() async throws {
        player.playQueue(items: [.init(id: source.id, url: audioURL, title: source.displayTitle, series: source.seriesName)])
        try await autoplayEventually("the original track to start") { self.player.isPlaying }
        #expect(player.currentTrackId == source.id)
        #expect(player.currentNarration == nil)
    }

    func remove() {
        preview.stopWaiting()
        timeline.release()
        player.stop()
        narrations.cancel()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    private static func writeAudio(to url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
        ])
        defer { file.close() }
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        let samples = try #require(buffer.floatChannelData)[0]
        let total = Int(format.sampleRate * 30)
        var offset = 0
        while offset < total {
            let count = min(4096, total - offset)
            buffer.frameLength = AVAudioFrameCount(count)
            for index in 0..<count {
                samples[index] = Float(0.01 * sin(2 * .pi * 170 * Double(offset + index) / format.sampleRate))
            }
            try file.write(from: buffer)
            offset += count
        }
    }
}

@MainActor
private final class AutoplayTimelineGate {
    private let composition: AVMutableComposition
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false
    private(set) var requests: [[URL]] = []
    private(set) var completedBuilds = 0

    init(composition: AVMutableComposition) { self.composition = composition }

    func build(_ urls: [URL]) async -> AVMutableComposition {
        requests.append(urls)
        // Native timeline work may finish after the listener changes their intent.
        if !isReleased { await withCheckedContinuation { continuation = $0 } }
        completedBuilds += 1
        return composition
    }

    func release() {
        isReleased = true
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

@MainActor
private final class AutoplayFixtureRenderer: NarrationSpeechRendering {
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
        throw AutoplayIntentTestError.unexpectedAssembly
    }

    func cancel() {}
}

@MainActor
private final class AutoplayVoiceSpeaker: NarrationVoicePreviewSpeaking {
    private(set) var spokenVoiceID: String?
    private var completion: (@MainActor @Sendable () -> Void)?

    func speak(
        text: String, voiceID: String, pace: NarrationPace,
        completion: @escaping @MainActor @Sendable () -> Void
    ) throws {
        spokenVoiceID = voiceID
        self.completion = completion
    }

    func finish() {
        let pending = completion
        completion = nil
        pending?()
    }

    func stop() { completion = nil }
}

@MainActor
private func autoplayEventually(_ description: String, _ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(condition(), "Timed out waiting for \(description)")
}

private enum AutoplayIntentTestError: Error {
    case unexpectedAssembly
}
#endif
