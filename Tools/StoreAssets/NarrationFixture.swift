import Foundation
@preconcurrency import Translation

// Builds a saved translation for store screenshots with the app's own NarrationService,
// Apple Translation and system voice on the Mac, because the simulator cannot translate.

@MainActor final class StubPlayer {
    let isPlaying = false
    let isPlayingNarrationPreview = false
    let currentNarration: NarrationDocument? = nil
}

@MainActor final class AppRuntime {
    static let shared = AppRuntime()
    let audioPlayer = StubPlayer()
}

@MainActor final class NarrationPreviewPlayback {
    static let shared = NarrationPreviewPlayback()
    let loadingDocumentID: String? = nil
}

@MainActor final class TranscriptService {
    static let shared = TranscriptService()
    var loaded: Transcript?
    func transcript(for discourseID: String) async throws -> Transcript {
        guard let loaded, loaded.discourseID == discourseID else { throw CocoaError(.fileNoSuchFile) }
        return loaded
    }
}

struct FixtureError: Error, CustomStringConvertible {
    let description: String
}

@main
struct NarrationFixture {
    @MainActor static func main() async {
        do {
            try await run()
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("NarrationFixture: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor static func run() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 5 else {
            throw FixtureError(description: "Usage: NarrationFixture TRANSCRIPT_JSON TARGET_LANGUAGE PACE NEW_OUTPUT_DIRECTORY")
        }
        let transcript = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
        let target = arguments[2]
        guard let pace = NarrationPace(rawValue: arguments[3]) else { throw FixtureError(description: "Unknown pace") }
        let output = URL(fileURLWithPath: arguments[4], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw FixtureError(description: "Output exists") }
        guard let entry = Catalog.discourseLookup[transcript.discourseID] else { throw FixtureError(description: "Not in catalog") }
        TranscriptService.shared.loaded = transcript

        let source = NarrationLanguageSupport.sourceLanguage(for: entry.series.language)
        let found = try await NarrationLanguageSupport.support(from: source, to: target)
        guard let support = found, support.status == .installed else {
            throw FixtureError(description: "\(source) -> \(target) is not installed for Apple Translation on this Mac: \(String(describing: found))")
        }
        let voices = NarrationLanguageSupport.compatibleVoices(NativeNarrationSpeechRenderer.availableVoices(), targetLanguage: target)
        guard let voice = voices.max(by: { $0.quality < $1.quality }) else { throw FixtureError(description: "No \(target) voice") }
        let selection = NarrationSelection(sourceLanguage: source, targetLanguage: target, voice: voice, pace: pace)
        let configuration = try NarrationLanguageSupport.configuration(source: source, target: target, strategy: support.strategy)
        let session = TranslationSession(installedSource: Locale.Language(identifier: source),
                                         target: Locale.Language(identifier: target),
                                         preferredStrategy: configuration.preferredStrategy)
        let lifetime = NarrationTranslationLifetime()
        lifetime.ownsServicePreparation = true
        defer {
            lifetime.ownsServicePreparation = false
            lifetime.invalidate()
            session.cancel()
        }
        try await AppleNarrationTranslator.prepare(using: session, lifetime: lifetime)

        let suite = "NarrationFixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = output.appendingPathComponent("narrations", isDirectory: true)
        let service = NarrationService(directory: cache, defaults: defaults, pacer: NarrationPausePacer())
        let started = Date()
        let document = try await service.prepare(
            transcript: transcript, selection: selection,
            translate: { texts in
                try await AppleNarrationTranslator.translate(
                    texts, using: session, sourceLanguage: source, targetLanguage: target, lifetime: lifetime
                )
            },
            renderer: NativeNarrationSpeechRenderer(rateScale: pace.voiceRateScale),
            onProgress: { partial in
                FileHandle.standardError.write(Data("\(partial.segments.count) of \(partial.expectedSegmentCount)\n".utf8))
            }
        )
        guard document.isComplete, service.audioURL(for: document) != nil else {
            throw FixtureError(description: "Preparation finished without complete audio")
        }
        let receipt: [String: Any] = [
            "documentID": document.id, "discourseID": document.discourseID,
            "sourceID": transcript.sourceID, "sourceLanguage": source, "targetLanguage": target,
            "voiceID": voice.id, "voiceName": voice.name, "voiceQuality": voice.quality, "pace": pace.rawValue,
            "strategy": String(describing: support.strategy), "passages": document.segments.count,
            "durationSeconds": document.duration, "elapsedSeconds": Date().timeIntervalSince(started),
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "scope": "Real catalog transcript, Apple Translation and system voice on macOS through the app's NarrationService.",
        ]
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("receipt.json"))
        FileHandle.standardOutput.write(data + Data([0x0a]))
    }
}
