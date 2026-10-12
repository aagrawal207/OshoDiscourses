import AVFoundation
import Darwin
import Foundation

private enum SpeechProbeError: Error {
    case usage, invalidNativeTranslation, noInstalledVoice, existingOutput, invalidManifest, silentOrTruncatedAudio
}

private struct NativeTranslationEvidence: Decodable, Sendable {
    let outcome: String
    let requestedSourceLanguage: String
    let requestedTargetLanguage: String
    let responseSourceLanguage: String
    let responseTargetLanguage: String
    let sourceText: String
    let targetText: String
    let canRequestDownloads: Bool
    let isReady: Bool
    let responseValidated: Bool
    let sampleAttribution: String
}

private struct SpeechEvidence: Encodable, Sendable {
    let event = "completed"
    let outcome = "rendered-cached-and-reloaded"
    let sampleAttribution: String
    let nativeTranslationReport: String
    let audioPath: String
    let manifestPath: String
    let document: NarrationDocument
    let cacheReloadValidated: Bool
    let returnedDuration: TimeInterval
    let decodedFrames: Int64
    let sampleRate: Double
    let rms: Double
    let bytes: Int
    let elapsedSeconds: Double
}

@main
struct NarrationTranslationSpeechProbe {
    nonisolated static func main() async {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(45)) {
            FileHandle.standardError.write(Data("Speech probe hard deadline: 45 seconds; exit 124.\n".utf8))
            exit(124)
        }
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.count == 2 else { throw SpeechProbeError.usage }
            let input = URL(fileURLWithPath: arguments[0])
            let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
            let translation = try JSONDecoder().decode(NativeTranslationEvidence.self, from: Data(contentsOf: input))
            guard translation.outcome == "translated", translation.isReady, translation.responseValidated,
                  !translation.canRequestDownloads,
                  translation.requestedSourceLanguage == translation.responseSourceLanguage,
                  translation.requestedTargetLanguage == translation.responseTargetLanguage,
                  !translation.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SpeechProbeError.invalidNativeTranslation
            }
            guard !FileManager.default.fileExists(atPath: directory.path) else { throw SpeechProbeError.existingOutput }
            let result = try await render(translation, input: input, directory: directory)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(result) + Data([0x0a]))
        } catch {
            FileHandle.standardError.write(Data("NarrationTranslationSpeechProbe: \(error)\n".utf8))
            exit(1)
        }
    }

    // Only Sendable evidence values cross into the renderer's main actor;
    // the native TranslationSession never leaves the translation process.
    @MainActor
    private static func render(
        _ translation: NativeTranslationEvidence, input: URL, directory: URL
    ) async throws -> SpeechEvidence {
        let start = ContinuousClock.now
        let target = Locale.Language(identifier: translation.responseTargetLanguage)
        guard let voice = NativeNarrationSpeechRenderer.availableVoices().first(where: {
            let language = Locale.Language(identifier: $0.language)
            return language.languageCode == target.languageCode && language.script == target.script
        }) else { throw SpeechProbeError.noInstalledVoice }
        let selection = NarrationSelection(
            sourceLanguage: translation.responseSourceLanguage, targetLanguage: translation.responseTargetLanguage, voice: voice
        )
        let transcript = Transcript(
            discourseID: "native-translation-probe-\(selection.sourceLanguage)-\(selection.targetLanguage)",
            sourceID: "original-philosophical-test-not-an-osho-quote", fetchedAt: Date(),
            paragraphs: [.init(index: 0, text: translation.sourceText, isEmphasis: false)]
        )
        let cacheDirectory = directory.appendingPathComponent("cache", isDirectory: true)
        let cache = NarrationCache(directory: cacheDirectory)
        let plan = try NarrationCache.Plan(transcript: transcript, selection: selection)
        let job = NarrationCache.Job()
        let renderer = NativeNarrationSpeechRenderer()
        let snapshot: NarrationCache.Snapshot
        do {
            stage("NarrationCache.start")
            _ = try await cache.start(plan: plan, job: job)
            let segment = try await cache.outputURL(segment: 0, job: job)
            stage("NativeNarrationSpeechRenderer.render voice=\(voice.id)")
            let renderedDuration = try await renderer.render(text: translation.targetText, voiceID: voice.id, to: segment)
            stage("NarrationCache.checkpoint")
            _ = try await cache.checkpoint(index: 0, text: translation.targetText, duration: renderedDuration, job: job)
            let segments = try await cache.segmentURLs(job: job)
            let assembly = try await cache.outputURL(segment: nil, job: job)
            stage("NativeNarrationSpeechRenderer.assemble")
            let duration = try await renderer.assemble(segments: segments, to: assembly)
            stage("NarrationCache.finish")
            snapshot = try await cache.finish(duration: duration, job: job)
            await cache.discardStaging(job: job)
        } catch {
            renderer.cancel()
            await cache.discardStaging(job: job)
            throw error
        }
        stage("NarrationCache.load in a fresh cache instance")
        let reloadedCache = NarrationCache(directory: cacheDirectory)
        let reloaded = try await reloadedCache.load()
        guard let entry = reloaded.first(where: { $0.document.id == snapshot.document.id }),
              entry.document == snapshot.document, entry.document.isComplete,
              entry.document.segments.first?.text == translation.targetText,
              let audio = reloadedCache.audioURL(for: entry) else { throw SpeechProbeError.invalidManifest }
        let audition = directory.appendingPathComponent("translated.m4a")
        try FileManager.default.copyItem(at: audio, to: audition)
        let file = try AVAudioFile(forReading: audition)
        defer { file.close() }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else {
            throw SpeechProbeError.silentOrTruncatedAudio
        }
        var frames: Int64 = 0
        var energy = 0.0
        while frames < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else {
                throw SpeechProbeError.silentOrTruncatedAudio
            }
            frames += Int64(buffer.frameLength)
            for frame in 0..<Int(buffer.frameLength) {
                let sample = Double(data[0][frame * buffer.stride])
                energy += sample * sample
            }
        }
        guard frames == file.length, frames > 0, energy.isFinite, energy > 0 else {
            throw SpeechProbeError.silentOrTruncatedAudio
        }
        let elapsed = start.duration(to: .now).components
        return SpeechEvidence(
            sampleAttribution: translation.sampleAttribution, nativeTranslationReport: input.path,
            audioPath: audition.path, manifestPath: audio.deletingLastPathComponent().appendingPathComponent("manifest.json").path,
            document: entry.document, cacheReloadValidated: true, returnedDuration: entry.document.duration,
            decodedFrames: frames, sampleRate: file.processingFormat.sampleRate, rms: sqrt(energy / Double(frames)),
            bytes: try audition.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0,
            elapsedSeconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        )
    }

    private static func stage(_ name: String) {
        FileHandle.standardError.write(Data("Native operation: \(name)\n".utf8))
    }
}
