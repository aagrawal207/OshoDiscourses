import AVFoundation
import CryptoKit
import Darwin
import Foundation
// The SDK session stays with one main-actor owner. Its async calls use the
// production lifetime gate, including the installed-only readiness check.
@preconcurrency import Translation

private enum PipelineProbeError: Error {
    case assertion(String)
}

private let nativeDeadlineSeconds = 180
private let sampleAttribution = "Nine original narration test paragraphs, not Osho quotations or a catalog transcript."
private let expectedBatchSizes = [4, 4, 1]

private struct PipelineCall: Encodable {
    enum Kind: String, Encodable { case translation, render, assemble }

    let id: Int
    let kind: Kind
    let inputs: [String]
    let voiceID: String?
    let outputPath: String?
    let startedSeconds: Double
    let inFlightAtStart: [String: Int]
    var finishedSeconds: Double?
    var inFlightAtFinish: [String: Int]?
    var outcome = "in-flight"
    var outputs: [String] = []
    var returnedDuration: TimeInterval?
    var errorDescription: String?
}

@MainActor
private final class PipelineEvidence {
    var stage = "initialization"
    var prepareCalls = 0
    private let start = ContinuousClock.now
    private(set) var calls: [PipelineCall] = []
    private(set) var maxTranslationsInFlight = 0
    private(set) var maxRendersInFlight = 0
    private(set) var maxAudioOperationsInFlight = 0
    private(set) var maxCombinedInFlight = 0
    private(set) var cancellationCalls: [[String: Any]] = []
    var pendingTextChecks: [[String: Any]] = []
    var allRenderedTextWasPending = true
    var report: [String: Any] = [
        "event": "completed", "operation": "production-pipeline",
        "platformScope": "Native macOS CLI; app UI and physical iPhone execution are not tested.",
        "sampleAttribution": sampleAttribution,
        "requestedStrategy": "highFidelity", "sourceLanguage": "en", "targetLanguage": "es",
        "expectedParagraphCount": 9, "expectedTranslationBatchSizes": expectedBatchSizes,
        "nativeDeadlineSeconds": nativeDeadlineSeconds,
        "uiFixture": ["enabled": false],
    ]

    var translations: [PipelineCall] { calls.filter { $0.kind == .translation } }
    var renders: [PipelineCall] { calls.filter { $0.kind == .render } }
    var assemblies: [PipelineCall] { calls.filter { $0.kind == .assemble } }
    var inputs: [String] { translations.flatMap(\.inputs) }
    var outputs: [String] { translations.flatMap(\.outputs) }

    var elapsedSeconds: Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }

    var inFlight: [String: Int] {
        let active = calls.filter { $0.finishedSeconds == nil }
        return [
            "translation": active.filter { $0.kind == .translation }.count,
            "render": active.filter { $0.kind == .render }.count,
            "assemble": active.filter { $0.kind == .assemble }.count,
        ]
    }

    func step(_ name: String) {
        stage = name
        emit(["event": "operation_begin", "operation": name, "timestampSeconds": elapsedSeconds, "inFlight": inFlight])
    }

    func begin(_ kind: PipelineCall.Kind, inputs: [String], voiceID: String? = nil, outputURL: URL? = nil) -> Int {
        var active = inFlight
        active[kind.rawValue, default: 0] += 1
        let index = calls.count
        calls.append(PipelineCall(
            id: index + 1, kind: kind, inputs: inputs, voiceID: voiceID, outputPath: outputURL?.path,
            startedSeconds: elapsedSeconds, inFlightAtStart: active
        ))
        maxTranslationsInFlight = max(maxTranslationsInFlight, active["translation", default: 0])
        maxRendersInFlight = max(maxRendersInFlight, active["render", default: 0])
        maxAudioOperationsInFlight = max(maxAudioOperationsInFlight, active["render", default: 0] + active["assemble", default: 0])
        maxCombinedInFlight = max(maxCombinedInFlight, active.values.reduce(0, +))
        stage = kind == .translation ? "AppleNarrationTranslator.translate" : "NativeNarrationSpeechRenderer.\(kind.rawValue)"
        emit([
            "event": "operation_begin", "operation": stage, "callID": index + 1,
            "timestampSeconds": calls[index].startedSeconds, "inFlight": active,
        ])
        return index
    }

    func finish(_ index: Int, outputs: [String] = [], duration: TimeInterval? = nil, error: Error? = nil) {
        let finished = elapsedSeconds
        calls[index].finishedSeconds = finished
        calls[index].inFlightAtFinish = inFlight
        calls[index].outputs = outputs
        calls[index].returnedDuration = duration
        calls[index].outcome = error == nil ? "succeeded" : "failed"
        calls[index].errorDescription = error.map { String(describing: $0) }
        emit([
            "event": "operation_end", "operation": calls[index].kind.rawValue, "callID": index + 1,
            "timestampSeconds": finished, "inFlight": inFlight,
            "outcome": calls[index].outcome,
        ])
    }

    func recordCancellation() {
        let event: [String: Any] = [
            "event": "cancel", "operation": "NativeNarrationSpeechRenderer.cancel",
            "timestampSeconds": elapsedSeconds, "inFlight": inFlight,
        ]
        cancellationCalls.append(event)
        emit(event)
    }

    var concurrency: [String: Any] {
        var overlaps: [[String: Any]] = []
        var overlapSeconds = 0.0
        for translation in translations {
            guard let translationEnd = translation.finishedSeconds else { continue }
            for render in renders {
                guard let renderEnd = render.finishedSeconds else { continue }
                let start = max(translation.startedSeconds, render.startedSeconds)
                let end = min(translationEnd, renderEnd)
                guard end > start else { continue }
                overlapSeconds += end - start
                overlaps.append([
                    "translationCallID": translation.id, "renderCallID": render.id,
                    "startedSeconds": start, "finishedSeconds": end, "seconds": end - start,
                ])
            }
        }
        return [
            "clock": "ContinuousClock seconds since probe start",
            "scope": "Completed production adapter/render call lifetimes, including scheduling and any native retry/backoff. SDK-internal work is not timed separately.",
            "observedTranslationRenderOverlap": !overlaps.isEmpty,
            "observation": overlaps.isEmpty ? "No translation/render overlap observed in this run." : "Translation/render call overlap observed in this run.",
            "translationRenderOverlapSeconds": overlapSeconds, "overlapIntervals": overlaps,
            "maxTranslationsInFlight": maxTranslationsInFlight, "maxRendersInFlight": maxRendersInFlight,
            "maxAudioOperationsInFlight": maxAudioOperationsInFlight, "maxCombinedInFlight": maxCombinedInFlight,
            "inFlightAtCompletion": inFlight, "wallClockSpeedupClaimed": false,
            "structuralOverlapTest": "NarrationServiceTests.translationOverlapsAudioWithOnlyOneBatchOfLookahead",
            "structuralOverlapTestExecutedByProbe": false,
        ]
    }

    private func emit(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event, options: .sortedKeys) else { return }
        FileHandle.standardOutput.write(data + Data([0x0a]))
    }
}

@MainActor
private final class RecordingNarrationSpeechRenderer: NarrationSpeechRendering {
    private let native = NativeNarrationSpeechRenderer()
    private let evidence: PipelineEvidence
    private let manifestURL: URL

    init(evidence: PipelineEvidence, manifestURL: URL) {
        self.evidence = evidence
        self.manifestURL = manifestURL
    }

    func render(text: String, voiceID: String, to outputURL: URL) async throws -> TimeInterval {
        recordPendingText(text, outputURL: outputURL)
        let call = evidence.begin(.render, inputs: [text], voiceID: voiceID, outputURL: outputURL)
        do {
            let duration = try await native.render(text: text, voiceID: voiceID, to: outputURL)
            evidence.finish(call, duration: duration)
            return duration
        } catch {
            evidence.finish(call, error: error)
            throw error
        }
    }

    func assemble(segments: [URL], to outputURL: URL) async throws -> TimeInterval {
        let call = evidence.begin(.assemble, inputs: segments.map(\.path), outputURL: outputURL)
        do {
            let duration = try await native.assemble(segments: segments, to: outputURL)
            evidence.finish(call, duration: duration)
            return duration
        } catch {
            evidence.finish(call, error: error)
            throw error
        }
    }

    func cancel() {
        evidence.recordCancellation()
        native.cancel()
    }

    private func recordPendingText(_ text: String, outputURL: URL) {
        let name = outputURL.lastPathComponent
        var observation: [String: Any] = [
            "renderAttempt": evidence.renders.count + 1, "outputFileName": name,
            "timestampSeconds": evidence.elapsedSeconds, "persistedBeforeRendering": false,
        ]
        do {
            guard name.hasPrefix("segment-"), name.hasSuffix(".m4a"),
                  let index = Int(name.dropFirst("segment-".count).dropLast(".m4a".count)),
                  let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any],
                  let pending = manifest["pendingTranslations"] as? [String: String] else {
                throw PipelineProbeError.assertion("Pending translation checkpoint could not be read")
            }
            observation["persistedBeforeRendering"] = pending[String(index)] == text
            observation["pendingSegmentIndices"] = pending.keys.compactMap { Int($0) }.sorted()
        } catch {
            observation["error"] = String(describing: error)
        }
        evidence.allRenderedTextWasPending = evidence.allRenderedTextWasPending
            && (observation["persistedBeforeRendering"] as? Bool == true)
        evidence.pendingTextChecks.append(observation)
    }
}

@MainActor
private final class RejectUnexpectedWork: NarrationSpeechRendering {
    private(set) var calls: [String] = []

    func translate(_ texts: [String]) throws -> [String] {
        calls.append("translate")
        throw PipelineProbeError.assertion("Ready-cache reuse invoked translation")
    }

    func render(text: String, voiceID: String, to outputURL: URL) async throws -> TimeInterval {
        calls.append("render")
        throw PipelineProbeError.assertion("Ready-cache reuse invoked speech synthesis")
    }

    func assemble(segments: [URL], to outputURL: URL) async throws -> TimeInterval {
        calls.append("assemble")
        throw PipelineProbeError.assertion("Ready-cache reuse invoked audio assembly")
    }

    func cancel() { calls.append("cancel") }
}

@main
struct NarrationTranslationPipelineProbe {
    @MainActor static func main() async {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(nativeDeadlineSeconds)) {
            FileHandle.standardError.write(Data("Pipeline hard deadline: \(nativeDeadlineSeconds) seconds; exit 124.\n".utf8))
            exit(124)
        }
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard !arguments.isEmpty, arguments.count % 2 == 1,
                  !arguments[0].isEmpty, !arguments[0].hasPrefix("--") else {
                throw PipelineProbeError.assertion("Usage: NarrationTranslationPipelineProbe NEW_OUTPUT_DIRECTORY [--ui-fixture CATALOG_DISCOURSE_ID] [--target LANGUAGE]")
            }
            let directory = URL(fileURLWithPath: arguments[0], isDirectory: true)
            var fixtureID: String?
            var target = "es"
            for index in stride(from: 1, to: arguments.count, by: 2) {
                switch arguments[index] {
                case "--ui-fixture": fixtureID = arguments[index + 1]
                case "--target": target = arguments[index + 1]
                default: throw PipelineProbeError.assertion("Unknown pipeline argument")
                }
            }
            FileHandle.standardError.write(Data("Sample attribution: \(sampleAttribution)\n".utf8))
            let (data, passed) = try await execute(directory: directory, fixtureID: fixtureID, target: target)
            FileHandle.standardOutput.write(data + Data([0x0a]))
            exit(passed ? 0 : 2)
        } catch {
            FileHandle.standardError.write(Data("Pipeline probe: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    private static func execute(directory: URL, fixtureID: String?, target: String) async throws -> (Data, Bool) {
        let evidence = PipelineEvidence()
        evidence.report["targetLanguage"] = target
        let suite = "NarrationTranslationProbe.pipeline.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw PipelineProbeError.assertion("Unable to create isolated defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        evidence.report["defaultsSuite"] = suite
        evidence.report["os"] = ProcessInfo.processInfo.operatingSystemVersionString
        evidence.report["outputDirectory"] = directory.path
        var passed = false
        do {
            try require(!FileManager.default.fileExists(atPath: directory.path), "Pipeline requires a fresh output directory")
            if let fixtureID {
                guard let entry = Catalog.discourseLookup[fixtureID] else {
                    throw PipelineProbeError.assertion("Unknown --ui-fixture catalog discourse ID: \(fixtureID)")
                }
                evidence.report["uiFixture"] = [
                    "enabled": true, "catalogDiscourseID": entry.discourse.id,
                    "catalogTitle": entry.discourse.displayTitle, "catalogLanguage": entry.series.language.rawValue,
                    "sampleSourceLanguage": "en", "sampleAttribution": sampleAttribution,
                    "scope": "Only the catalog ID is reused. This cache contains the same original test text as the standalone probe.",
                ]
            }
            let source = NarrationLanguageSupport.sourceLanguage(for: SeriesInfo.Language.english)
            try await checkInstalledSupport(source: source, target: target, evidence: evidence)
            let voices = NarrationLanguageSupport.compatibleVoices(
                NativeNarrationSpeechRenderer.availableVoices(), targetLanguage: target
            )
            guard let voice = voices.first else { throw PipelineProbeError.assertion("No installed voice for \(target)") }
            let selection = NarrationSelection(sourceLanguage: source, targetLanguage: target, voice: voice)
            let paragraphs = [
                "Original test passage one, not an Osho quotation: Notice a thought without holding on to it. A quiet moment can make room for kindness.",
                "Original test passage two: Listen before you answer. Patience can turn a disagreement into a chance to understand.",
                "Original test passage three: A gardener checks the soil before adding water. Care begins with noticing what is needed.",
                "Original test passage four: Set one task aside when a friend needs your attention. A small pause can be a generous gift.",
                "Original test passage five: A cloud can hide the hill without moving it. A passing worry need not decide the whole day.",
                "Original test passage six: Learn the rhythm of a walk before choosing a destination. Each ordinary step can teach balance.",
                "Original test passage seven: When a plan changes, name what is still possible. Flexibility leaves room for a useful next step.",
                "Original test passage eight: Share credit when a difficult task is finished. Gratitude helps a group remember how it worked together.",
                "Original test passage nine: End the day by recalling one act of care. Let that memory guide a kind choice tomorrow.",
            ]
            let transcript = Transcript(
                discourseID: fixtureID ?? "native-pipeline-probe-en-\(target)",
                sourceID: "original-philosophical-test-not-an-osho-quote", fetchedAt: Date(),
                paragraphs: paragraphs.enumerated().map { .init(index: $0.offset, text: $0.element, isEmphasis: false) }
            )
            evidence.report["sourceTranscript"] = try jsonValue(transcript)
            let plan = try NarrationCache.Plan(transcript: transcript, selection: selection)
            try require(paragraphs.count == 9 && plan.chunks.count == 9, "Expected nine short, unsplit test paragraphs")
            let cacheDirectory = directory.appendingPathComponent("cache", isDirectory: true)
            let service = NarrationService(directory: cacheDirectory, defaults: defaults)
            let renderer = RecordingNarrationSpeechRenderer(
                evidence: evidence,
                manifestURL: cacheDirectory.appendingPathComponent(plan.document.id).appendingPathComponent("manifest.json")
            )
            let document = try await prepareFresh(
                service: service, transcript: transcript, selection: selection, renderer: renderer, evidence: evidence
            )
            evidence.step("Validate native batch, checkpoint and audio order")
            try require(document.isComplete && document.expectedSegmentCount == 9 && document.segments.count == 9, "Incomplete nine-paragraph narration")
            try require(document.id == plan.document.id && document.sourceDigest == plan.document.sourceDigest, "Service changed rendition provenance")
            try require(evidence.prepareCalls == 1 && evidence.translations.map({ $0.inputs.count }) == expectedBatchSizes, "Expected one native preparation and three translation batches (4 + 4 + 1)")
            try require(evidence.translations.allSatisfy { $0.inputs.count <= 4 && $0.inputs.reduce(0, { $0 + $1.utf16.count }) <= 6_000 }, "Translation batch exceeded its chunk or UTF16 bound")
            try require(evidence.translations.allSatisfy { $0.outcome == "succeeded" && $0.outputs.count == $0.inputs.count }, "A native translation batch returned an incomplete response")
            try require(evidence.inputs == transcript.paragraphs.map(\.text), "Service changed source paragraph order")
            let indices = Array(0..<9)
            let translated = evidence.outputs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            try require(document.segments.map(\.index) == indices && document.segments.map(\.sourceParagraphIndex) == indices, "Persisted segment indices changed order")
            try require(document.segments.map(\.text) == translated, "Manifest differs from the adapter's ordered, trimmed output")
            let rendered = evidence.renders.filter { $0.outcome == "succeeded" }
            try require(rendered.count == 9 && rendered.flatMap(\.inputs) == translated, "Native renderer did not receive all translated passages in order")
            try require(rendered.allSatisfy { $0.voiceID == voice.id }, "Native renderer received a different voice")
            let attempts = Dictionary(grouping: evidence.renders, by: \.outputPath)
            try require(attempts.count == 9 && attempts.values.allSatisfy { $0.count <= 2 }, "Speech retry exceeded two attempts per passage")
            try require(evidence.allRenderedTextWasPending && evidence.pendingTextChecks.count == evidence.renders.count, "Translated text was not persisted before every native render attempt")
            try require(evidence.maxTranslationsInFlight == 1 && evidence.maxAudioOperationsInFlight == 1, "Native translation or audio operations were not serial within their lane")
            try require(evidence.inFlight.values.allSatisfy { $0 == 0 }, "Preparation returned with native work in flight")
            try require(!service.isPreparing && service.progress == 1 && service.errorMessage == nil, "Service did not publish ready state")
            guard let audio = service.audioURL(for: document) else { throw PipelineProbeError.assertion("Ready service did not vend audio") }
            let folder = audio.deletingLastPathComponent()
            let manifest = folder.appendingPathComponent("manifest.json")
            let segmentURLs = document.segments.map { folder.appendingPathComponent($0.audioFileName) }
            try require(rendered.compactMap { $0.outputPath.map { URL(fileURLWithPath: $0).lastPathComponent } } == document.segments.map(\.audioFileName), "Rendered audio file order differs from the manifest")
            try require(evidence.assemblies.count == 1 && evidence.assemblies.first?.outcome == "succeeded"
                && evidence.assemblies.first?.inputs == segmentURLs.map(\.path), "Assembly did not receive all nine committed segments in order")
            let files = segmentURLs + [audio, manifest]
            let before = try fingerprints(files)
            evidence.report["document"] = try jsonValue(document)
            evidence.report["audioPath"] = audio.path
            evidence.report["manifestPath"] = manifest.path
            evidence.report["cacheEntryDirectory"] = folder.path
            evidence.report["files"] = try audioEvidence(document: document, folder: folder)
            evidence.report["assemblyDuration"] = [
                "sumOfSegmentSeconds": document.segments.reduce(0) { $0 + $1.duration },
                "assembledSeconds": document.duration,
            ]
            evidence.report["fileSHA256BeforeReuse"] = before
            evidence.report["responseOrder"] = [
                "scope": "Order returned by the production adapter and persisted by the service; private SDK arrival order is not exposed.",
                "sourceParagraphIndices": transcript.paragraphs.map(\.index),
                "adapterOutputs": evidence.outputs, "trimmedAdapterOutputs": translated,
                "persistedSegmentIndices": document.segments.map(\.index),
                "persistedSourceParagraphIndices": document.segments.map(\.sourceParagraphIndex),
                "persistedTextMatchesOrderedAdapterOutput": document.segments.map(\.text) == evidence.outputs,
                "persistedTextMatchesTrimmedOrderedAdapterOutput": true,
                "renderedTextMatchesPersistedText": true, "assemblyInputPaths": evidence.assemblies[0].inputs,
            ]

            let position = min(1.25, document.duration / 2)
            service.savePosition(documentID: document.id, position: position)
            guard let reloadedDefaults = UserDefaults(suiteName: suite) else {
                throw PipelineProbeError.assertion("Unable to reopen isolated defaults")
            }
            let reloadedService = NarrationService(directory: cacheDirectory, defaults: reloadedDefaults)
            evidence.step("NarrationService.load in a fresh service without a translator")
            await reloadedService.load()
            try require(reloadedService.errorMessage == nil && reloadedService.documents == [document], "Fresh service did not load the ready document")
            try require(reloadedService.audioURL(for: document) == audio, "Fresh service did not vend the same verified audio")
            try require(reloadedService.position(for: document.id) == position, "Narration position did not round-trip")
            evidence.report["readyCacheLoadedWithoutTranslator"] = true
            evidence.report["positionRoundTrip"] = [
                "documentID": document.id, "writtenSeconds": position,
                "readFromFreshServiceSeconds": reloadedService.position(for: document.id),
            ]

            let reject = RejectUnexpectedWork()
            evidence.step("NarrationService.prepare on ready cache with fail-if-called translation and rendering")
            let reused = try await reloadedService.prepare(
                transcript: transcript, selection: selection,
                translate: { try reject.translate($0) }, renderer: reject
            )
            try require(reject.calls.isEmpty, "Ready-cache reuse invoked unexpected work: \(reject.calls)")
            try require(reused == document && reloadedService.audioURL(for: reused) == audio, "Cache reuse changed the document or audio")
            try require(!reloadedService.isPreparing && reloadedService.progress == 1 && reloadedService.errorMessage == nil, "Cache reuse did not publish ready state")
            let after = try fingerprints(files)
            try require(before == after, "Cache reuse rewrote manifest or audio bytes")
            evidence.report["readyCacheReuse"] = [
                "passed": true, "failIfCalledTranslatorAndRendererInvocations": reject.calls,
                "documentUnchanged": reused == document, "manifestAndAudioHashesUnchanged": before == after,
            ]
            evidence.report["fileSHA256AfterReuse"] = after
            passed = true
        } catch {
            let native = error as NSError
            evidence.report["failedStage"] = evidence.stage
            evidence.report["error"] = [
                "swiftType": String(reflecting: type(of: error)), "description": String(describing: error),
                "domain": native.domain, "code": native.code, "localizedDescription": native.localizedDescription,
            ]
        }
        defaults.removePersistentDomain(forName: suite)
        evidence.report["defaultsSuiteCleared"] = defaults.persistentDomain(forName: suite)?.isEmpty ?? true
        evidence.report["actualApplePreparationCalls"] = evidence.prepareCalls
        evidence.report["actualAppleTranslationBatches"] = evidence.translations.count
        evidence.report["translationBatchCountScope"] = "Production adapter invocations; SDK-internal retry attempts are not exposed by the adapter."
        evidence.report["translationBatchSizes"] = evidence.translations.map { $0.inputs.count }
        evidence.report["translationBatchUTF16Counts"] = evidence.translations.map { $0.inputs.reduce(0) { $0 + $1.utf16.count } }
        evidence.report["callTimeline"] = try jsonValue(evidence.calls)
        evidence.report["nativeRendererCancellationCalls"] = evidence.cancellationCalls
        evidence.report["concurrency"] = evidence.concurrency
        evidence.report["pendingTextBeforeRender"] = evidence.pendingTextChecks
        evidence.report["retryObservation"] = [
            "nativeTranslationAttemptCount": NSNull(), "injectedFailures": false,
            "translationScope": "Retries, if any, remain inside AppleNarrationTranslator; call timing includes native backoff.",
            "speechRenderAttempts": evidence.renders.count,
            "speechRetryAttemptsObserved": Dictionary(grouping: evidence.renders, by: \.outputPath).values.reduce(0) { $0 + max(0, $1.count - 1) },
        ]
        evidence.report["outcome"] = passed ? "pipeline-passed" : "pipeline-failed"
        evidence.report["elapsedSeconds"] = evidence.elapsedSeconds
        return (try JSONSerialization.data(withJSONObject: evidence.report, options: [.sortedKeys, .withoutEscapingSlashes]), passed)
    }

    @MainActor
    private static func checkInstalledSupport(source: String, target: String, evidence: PipelineEvidence) async throws {
        evidence.step("NarrationLanguageSupport.support \(source) -> \(target)")
        guard let support = try await NarrationLanguageSupport.support(from: source, to: target) else {
            throw PipelineProbeError.assertion("Production language helper reports no support")
        }
        evidence.report["productionLanguageSupport"] = ["strategy": support.strategy.rawValue, "status": String(describing: support.status)]
        try require(support.strategy == .highFidelity && support.status == .installed, "High-fidelity \(source) -> \(target) is not installed")
    }

    @MainActor
    private static func prepareFresh(
        service: NarrationService, transcript: Transcript, selection: NarrationSelection,
        renderer: RecordingNarrationSpeechRenderer, evidence: PipelineEvidence
    ) async throws -> NarrationDocument {
        let session = TranslationSession(
            installedSource: Locale.Language(identifier: selection.sourceLanguage),
            target: Locale.Language(identifier: selection.targetLanguage), preferredStrategy: .highFidelity
        )
        let lifetime = NarrationTranslationLifetime()
        defer {
            lifetime.ownsServicePreparation = false
            lifetime.invalidate()
            session.cancel()
            evidence.report["translationLifetimeInvalidatedBeforeReload"] = !lifetime.isActive
        }
        evidence.report["canRequestDownloads"] = session.canRequestDownloads
        try require(!session.canRequestDownloads, "Session unexpectedly permits downloads")
        evidence.step("TranslationSession.isReady through production lifetime gate")
        let ready = try await lifetime.withNativeOperation(sessionID: ObjectIdentifier(session)) { await session.isReady }
        evidence.report["isReadyBeforePreparation"] = ready
        try require(ready, "Installed-only session is not ready")
        lifetime.ownsServicePreparation = true
        var prepared = false
        evidence.step("NarrationService.prepare with production translator and renderer")
        return try await service.prepare(
            transcript: transcript, selection: selection,
            translate: { texts in
                if !prepared {
                    evidence.step("AppleNarrationTranslator.prepare using installed-only session")
                    evidence.prepareCalls += 1
                    try await AppleNarrationTranslator.prepare(using: session, lifetime: lifetime)
                    prepared = true
                    evidence.report["nativePreparationSucceeded"] = true
                }
                let call = evidence.begin(.translation, inputs: texts)
                do {
                    let translated = try await AppleNarrationTranslator.translate(
                        texts, using: session, sourceLanguage: selection.sourceLanguage,
                        targetLanguage: selection.targetLanguage, lifetime: lifetime
                    )
                    evidence.finish(call, outputs: translated)
                    return translated
                } catch {
                    evidence.finish(call, error: error)
                    throw error
                }
            },
            renderer: renderer
        )
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw PipelineProbeError.assertion(message) }
    }

    private static func jsonValue<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    private static func fingerprints(_ files: [URL]) throws -> [String: String] {
        try Dictionary(uniqueKeysWithValues: files.map { url in
            (url.lastPathComponent, SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined())
        })
    }

    private static func audioEvidence(document: NarrationDocument, folder: URL) throws -> [[String: Any]] {
        let expected = document.segments.map { ($0.audioFileName, $0.duration) } + [(document.audioFileName!, document.duration)]
        return try expected.map { name, duration in
            let url = folder.appendingPathComponent(name)
            let audio = try AVAudioFile(forReading: url)
            defer { audio.close() }
            let format = audio.processingFormat
            let rate = format.sampleRate
            let codec = audio.fileFormat.streamDescription.pointee.mFormatID
            try require(codec == kAudioFormatMPEG4AAC && rate.isFinite && rate > 0 && audio.length > 0, "Output is not nonempty AAC audio")
            let measured = Double(audio.length) / rate
            try require(measured.isFinite && abs(measured - duration) < 0.000_001, "Audio duration does not match the production manifest")
            guard (1...2).contains(format.channelCount),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192),
                  let channels = buffer.floatChannelData else {
                throw PipelineProbeError.assertion("AAC output cannot be decoded to PCM")
            }
            var decoded: AVAudioFramePosition = 0
            var energy = 0.0
            while decoded < audio.length {
                try audio.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, audio.length - decoded)))
                try require(buffer.frameLength > 0, "AAC output is truncated")
                decoded += AVAudioFramePosition(buffer.frameLength)
                for channel in 0..<Int(format.channelCount) {
                    for frame in 0..<Int(buffer.frameLength) {
                        let sample = Double(channels[channel][frame * buffer.stride])
                        try require(sample.isFinite, "Decoded AAC contains non-finite samples")
                        energy += sample * sample
                    }
                }
            }
            try require(decoded == audio.length && energy.isFinite && energy > 0, "AAC output is incomplete or silent")
            return [
                "path": url.path, "bytes": try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0,
                "frames": audio.length, "decodedFrames": decoded, "sampleRate": rate, "channels": format.channelCount,
                "codec": codec, "isAAC": true, "finitePCM": true, "nonSilent": true,
                "rms": sqrt(energy / (Double(decoded) * Double(format.channelCount))),
                "measuredDuration": measured, "manifestDuration": duration,
            ]
        }
    }
}
