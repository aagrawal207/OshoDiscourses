import Foundation
import Testing
import Translation
@testable import OshoDiscourses

@Suite
struct NarrationLanguageTests {
    @Test func catalogSourcesUseTranslationLanguageCodes() {
        #expect(NarrationLanguageSupport.sourceLanguage(for: .english) == "en")
        #expect(NarrationLanguageSupport.sourceLanguage(for: .hindi) == "hi")
        #expect(NarrationLanguageSupport.isSameLanguage("en", "en-GB"))
        #expect(NarrationLanguageSupport.isSameLanguage("hi", "hi-Deva-IN"))
        #expect(!NarrationLanguageSupport.isSameLanguage("en", "hi"))
    }

    @Test func voiceMatchingRespectsInferredAndExplicitScripts() {
        let voices = [voice("simplified", "zh-CN"), voice("traditional", "zh-TW"), voice("english", "en-US")]
        #expect(NarrationLanguageSupport.compatibleVoices(voices, targetLanguage: "zh-Hans").map(\.id) == ["simplified"])
        #expect(NarrationLanguageSupport.compatibleVoices(voices, targetLanguage: "zh-Hant").map(\.id) == ["traditional"])
        let serbian = [voice("latin", "sr-Latn-RS"), voice("cyrillic", "sr-RS")]
        #expect(NarrationLanguageSupport.compatibleVoices(serbian, targetLanguage: "sr-Latn").map(\.id) == ["latin"])
        #expect(NarrationLanguageSupport.compatibleVoices(serbian, targetLanguage: "sr-Cyrl").map(\.id) == ["cyrillic"])
    }

    @Test func compatibleRegionalVoicesAreDeduplicatedAndBestQualityLeads() {
        let british = voice("british", "en-GB", quality: 3)
        let voices = [voice("us", "en-US"), british, british, voice("hindi", "hi-IN", quality: 3)]
        #expect(NarrationLanguageSupport.compatibleVoices(voices, targetLanguage: "en").map(\.id) == ["british", "us"])
        #expect(NarrationLanguageSupport.compatibleVoices(voices, targetLanguage: "fr").isEmpty)
    }

    @available(macCatalyst 26.0, *)
    @Test(arguments: [LanguageAvailability.Status.installed, .supported])
    func highFidelityIsPreferredOnlyWhenRuntimeSupportsIt(_ status: LanguageAvailability.Status) {
        #expect(NarrationLanguageSupport.preferredSupport(highFidelity: status, standard: .installed)
                == NarrationTranslationSupport(strategy: .highFidelity, status: status))
    }

    @available(macCatalyst 26.0, *)
    @Test(arguments: [LanguageAvailability.Status.installed, .supported])
    func unsupportedHighFidelityFallsBackToTraditional(_ status: LanguageAvailability.Status) {
        let expected = NarrationTranslationSupport(strategy: .standard, status: status)
        #expect(NarrationLanguageSupport.preferredSupport(highFidelity: .unsupported, standard: status) == expected)
        #expect(NarrationLanguageSupport.preferredSupport(highFidelity: nil, standard: status) == expected)
    }

    @available(macCatalyst 26.0, *)
    @Test func noSupportedStrategyMeansNoTranslation() {
        #expect(NarrationLanguageSupport.preferredSupport(highFidelity: .unsupported, standard: .unsupported) == nil)
        #expect(NarrationLanguageSupport.preferredSupport(highFidelity: nil, standard: .unsupported) == nil)
    }

    @available(macCatalyst 26.0, *)
    @Test func discoveryUsesRuntimePairSupportAndExcludesSourceVariants() async throws {
        let candidates = ["en", "en-GB", "fr", "es"].map { Locale.Language(identifier: $0) }
        let options = try await NarrationLanguageSupport.availableLanguages(
            sourceLanguage: "en", voices: [voice("french", "fr-FR"), voice("spanish", "es-ES")], candidates: candidates
        ) { target in
            #expect(!NarrationLanguageSupport.isSameLanguage(target, "en"))
            return target == "fr" ? NarrationTranslationSupport(strategy: .standard, status: .supported) : nil
        }
        #expect(options.map(\.id) == ["fr"])
        #expect(options.first?.voices.map(\.id) == ["french"])
        #expect(options.first?.support.status == .supported)
    }

    @available(macCatalyst 26.0, *)
    @Test func aHindiVoiceDoesNotEstablishHindiTranslationSupport() async throws {
        let options = try await NarrationLanguageSupport.availableLanguages(
            sourceLanguage: "hi", voices: [voice("hindi", "hi-IN"), voice("english", "en-US")],
            candidates: [Locale.Language(identifier: "en"), Locale.Language(identifier: "hi")]
        ) { _ in nil }
        #expect(options.isEmpty)
    }

    @available(macCatalyst 26.0, *)
    @Test func discoveryRetainsSupportedLanguageWithNoCurrentVoice() async throws {
        let options = try await NarrationLanguageSupport.availableLanguages(
            sourceLanguage: "en", voices: [], candidates: [Locale.Language(identifier: "fr")]
        ) { _ in NarrationTranslationSupport(strategy: .standard, status: .installed) }
        #expect(options.count == 1)
        #expect(options.first?.voices.isEmpty == true)
    }

    @available(macCatalyst 26.0, *)
    @Test func discoveryDeduplicatesEquivalentTagsWithoutMergingScripts() async throws {
        let options = try await NarrationLanguageSupport.availableLanguages(
            sourceLanguage: "en", voices: [voice("simplified", "zh-CN"), voice("traditional", "zh-TW")],
            candidates: ["zh-Hans", "zh-CN", "zh-Hant", "zh-TW"].map { Locale.Language(identifier: $0) }
        ) { _ in NarrationTranslationSupport(strategy: .standard, status: .installed) }
        #expect(options.count == 2)
        #expect(Set(options.flatMap(\.voices).map(\.id)) == ["simplified", "traditional"])
    }

    @available(macCatalyst 26.0, *)
    @Test func cancelledAvailabilityDoesNotReportUnsupported() async {
        let task = Task {
            try await NarrationLanguageSupport.availableLanguages(
                sourceLanguage: "en", voices: [], candidates: [Locale.Language(identifier: "fr")]
            ) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return nil
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @available(macCatalyst 26.0, *)
    @Test func configurationPreservesPairAndSelectedStrategy() throws {
        let configuration = try NarrationLanguageSupport.configuration(source: "en", target: "zh-Hant", strategy: .standard)
        #expect(configuration.source == Locale.Language(identifier: "en"))
        #expect(configuration.target == Locale.Language(identifier: "zh-Hant"))
        if #available(iOS 26.4, macCatalyst 26.4, macOS 26.4, *) {
            #expect(configuration.preferredStrategy == .lowLatency)
            let highFidelity = try NarrationLanguageSupport.configuration(source: "hi", target: "en", strategy: .highFidelity)
            #expect(highFidelity.preferredStrategy == .highFidelity)
        } else {
            #expect(throws: NarrationTranslationError.unsupportedPair) {
                try NarrationLanguageSupport.configuration(source: "hi", target: "en", strategy: .highFidelity)
            }
        }
        #expect(throws: NarrationTranslationError.unsupportedPair) {
            try NarrationLanguageSupport.configuration(source: "en", target: "en-GB", strategy: .standard)
        }
    }

    private func voice(_ id: String, _ language: String, quality: Int = 1) -> NarrationVoice {
        NarrationVoice(id: id, name: id, language: language, quality: quality)
    }
}

@Suite
struct AppleNarrationTranslatorTests {
    @available(macCatalyst 26.0, *)
    @Test @MainActor func nativeBatchWrapperCorrelatesReorderedResponses() async throws {
        var calls = 0
        var sleeps = 0
        let translated = try await AppleNarrationTranslator.translate(
            ["One", "Two"], sourceLanguage: "en", targetLanguage: "fr", lifetime: NarrationTranslationLifetime(),
            sleep: { _ in sleeps += 1 }
        ) { texts in
            calls += 1
            #expect(texts == ["One", "Two"])
            let requests = try AppleNarrationTranslator.requests(for: texts)
            #expect(requests.map(\.clientIdentifier) == ["0", "1"])
            return [response("1", text: "Deux"), response("0", text: "Un")]
        }
        #expect(translated == ["Un", "Deux"])
        #expect(calls == 1)
        #expect(sleeps == 0)
    }

    @available(macCatalyst 26.0, *)
    @Test(arguments: [1, 2])
    @MainActor func transientNativeFailuresRetryThenSucceed(_ failures: Int) async throws {
        var calls = 0
        var delays: [Duration] = []
        let translated = try await AppleNarrationTranslator.translate(
            ["One", "Two"], sourceLanguage: "en", targetLanguage: "fr", lifetime: NarrationTranslationLifetime(),
            sleep: { delays.append($0) }
        ) { texts in
            calls += 1
            #expect(texts == ["One", "Two"])
            if calls <= failures { throw TranslationError.internalError }
            return [response("1", text: "Deux"), response("0", text: "Un")]
        }
        #expect(translated == ["Un", "Deux"])
        #expect(calls == failures + 1)
        let expectedDelays: [Duration] = failures == 1 ? [.milliseconds(500)] : [.milliseconds(500), .seconds(1)]
        #expect(delays == expectedDelays)
    }

    @available(macCatalyst 26.0, *)
    @Test @MainActor func transientFailuresStopAfterThreeAttemptsAndReleaseSession() async throws {
        let lifetime = NarrationTranslationLifetime()
        let session = NSObject()
        defer { withExtendedLifetime(session) {} }
        var calls = 0
        var delays: [Duration] = []
        await #expect(throws: NarrationTranslationError.translationFailed) {
            try await lifetime.withNativeOperation(sessionID: ObjectIdentifier(session)) {
                try await AppleNarrationTranslator.translate(
                    ["One"], sourceLanguage: "en", targetLanguage: "fr", lifetime: lifetime,
                    sleep: { delays.append($0) }
                ) { _ in
                    calls += 1
                    throw TranslationError.internalError
                }
            }
        }
        #expect(calls == 3)
        #expect(delays == [.milliseconds(500), .seconds(1)])
        let available = try await lifetime.withNativeOperation(sessionID: ObjectIdentifier(session)) { true }
        #expect(available)
    }

    enum InvalidBatch: CaseIterable, Sendable {
        case duplicate, missing, extra, missingIdentifier, unknownIdentifier, emptyText, wrongSource, wrongTarget
    }

    @available(macCatalyst 26.0, *)
    @Test(arguments: InvalidBatch.allCases)
    @MainActor func malformedNativeResponsesAreRejected(_ kind: InvalidBatch) async throws {
        var responses = [response("0", text: "Un"), response("1", text: "Deux")]
        switch kind {
        case .duplicate: responses[1] = response("0", text: "Encore")
        case .missing: responses.removeLast()
        case .extra: responses.append(response("2", text: "Trois"))
        case .missingIdentifier: responses[1] = response(nil, text: "Deux")
        case .unknownIdentifier: responses[1] = response("outside-the-batch", text: "Deux")
        case .emptyText: responses[1] = response("1", text: " \n\t ")
        case .wrongSource: responses[1] = response("1", text: "Deux", source: "hi")
        case .wrongTarget: responses[1] = response("1", text: "Two", target: "en")
        }
        let requests = try AppleNarrationTranslator.requests(for: ["One", "Two"])
        #expect(throws: NarrationTranslationError.invalidResponse) {
            try AppleNarrationTranslator.orderedTranslations(responses, requests: requests, sourceLanguage: "en", targetLanguage: "fr")
        }
        var calls = 0
        var sleeps = 0
        await #expect(throws: NarrationTranslationError.invalidResponse) {
            try await AppleNarrationTranslator.translate(
                ["One", "Two"], sourceLanguage: "en", targetLanguage: "fr", lifetime: NarrationTranslationLifetime(),
                sleep: { _ in sleeps += 1 }
            ) { _ in
                calls += 1
                return responses
            }
        }
        #expect(calls == 1)
        #expect(sleeps == 0)
    }

    @available(macCatalyst 26.0, *)
    @Test func responseScriptMustMatchRequestedScript() throws {
        let requests = try AppleNarrationTranslator.requests(for: ["Hello"])
        #expect(throws: NarrationTranslationError.invalidResponse) {
            try AppleNarrationTranslator.orderedTranslations(
                [response("0", text: "你好", target: "zh-Hans")], requests: requests,
                sourceLanguage: "en", targetLanguage: "zh-Hant"
            )
        }
    }

    @available(macCatalyst 26.0, *)
    @Test(arguments: [false, true])
    @MainActor func invalidResponseScriptsNeverRetry(_ wrongSource: Bool) async {
        var calls = 0
        var sleeps = 0
        await #expect(throws: NarrationTranslationError.invalidResponse) {
            try await AppleNarrationTranslator.translate(
                ["Hello"], sourceLanguage: wrongSource ? "zh-Hant" : "en",
                targetLanguage: wrongSource ? "fr" : "zh-Hant", lifetime: NarrationTranslationLifetime(),
                sleep: { _ in sleeps += 1 }
            ) { _ in
                calls += 1
                return [response("0", text: "Translation", source: wrongSource ? "zh-Hans" : "en",
                                 target: wrongSource ? "fr" : "zh-Hans")]
            }
        }
        #expect(calls == 1)
        #expect(sleeps == 0)
    }

    @available(macCatalyst 26.0, *)
    @Test @MainActor func invalidResponseAfterTransientFailureStopsRetrying() async {
        var calls = 0
        var delays: [Duration] = []
        await #expect(throws: NarrationTranslationError.invalidResponse) {
            try await AppleNarrationTranslator.translate(
                ["One"], sourceLanguage: "en", targetLanguage: "fr", lifetime: NarrationTranslationLifetime(),
                sleep: { delays.append($0) }
            ) { _ in
                calls += 1
                if calls == 1 { throw TranslationError.internalError }
                return [response("unknown", text: "Un")]
            }
        }
        #expect(calls == 2)
        #expect(delays == [.milliseconds(500)])
    }

    @available(macCatalyst 26.0, *)
    @Test func unchangedProperNamesRemainValidTranslations() throws {
        let requests = try AppleNarrationTranslator.requests(for: ["Osho"])
        #expect(try AppleNarrationTranslator.orderedTranslations(
            [response("0", text: "Osho")], requests: requests, sourceLanguage: "en", targetLanguage: "fr"
        ) == ["Osho"])
    }

    @available(macCatalyst 26.0, *)
    @Test(arguments: [[], [""], [" \n\t"], ["One", " "]])
    @MainActor func emptySourceInputIsRejected(_ input: [String]) async {
        #expect(throws: NarrationTranslationError.emptyInput) { try AppleNarrationTranslator.requests(for: input) }
        var calls = 0
        var sleeps = 0
        await #expect(throws: NarrationTranslationError.emptyInput) {
            try await AppleNarrationTranslator.translate(
                input, sourceLanguage: "en", targetLanguage: "fr", lifetime: NarrationTranslationLifetime(),
                sleep: { _ in sleeps += 1 }
            ) { _ in calls += 1; return [] }
        }
        #expect(calls == 0)
        #expect(sleeps == 0)
    }

    @available(macCatalyst 26.0, *)
    @Test @MainActor func sameLanguageNeverCallsNativeTranslation() async {
        var calls = 0
        var sleeps = 0
        await #expect(throws: NarrationTranslationError.unsupportedPair) {
            try await AppleNarrationTranslator.translate(
                ["One"], sourceLanguage: "en", targetLanguage: "en-GB", lifetime: NarrationTranslationLifetime(),
                sleep: { _ in sleeps += 1 }
            ) { _ in calls += 1; return [] }
        }
        #expect(calls == 0)
        #expect(sleeps == 0)
    }

    @available(macCatalyst 26.0, *)
    @Test @MainActor func aRetiredViewNeverTouchesItsSession() async {
        let lifetime = NarrationTranslationLifetime()
        lifetime.invalidate()
        var calls = 0
        var sleeps = 0
        await #expect(throws: CancellationError.self) {
            try await AppleNarrationTranslator.prepare(lifetime: lifetime) { calls += 1 }
        }
        await #expect(throws: CancellationError.self) {
            try await AppleNarrationTranslator.translate(
                ["One"], sourceLanguage: "en", targetLanguage: "fr", lifetime: lifetime,
                sleep: { _ in sleeps += 1 }
            ) { _ in
                calls += 1
                return [response("0", text: "Un")]
            }
        }
        #expect(calls == 0)
        #expect(sleeps == 0)
    }

    @available(macCatalyst 26.0, *)
    @Test @MainActor func cancellationDuringConsentRejectsLateCompletion() async {
        let lifetime = NarrationTranslationLifetime()
        await #expect(throws: CancellationError.self) {
            try await AppleNarrationTranslator.prepare(lifetime: lifetime) { lifetime.invalidate() }
        }
    }

    @available(macCatalyst 26.0, *)
    @Test @MainActor func cancellationDuringTranslationRejectsLateResponse() async {
        let lifetime = NarrationTranslationLifetime()
        await #expect(throws: CancellationError.self) {
            try await AppleNarrationTranslator.translate(["One"], sourceLanguage: "en", targetLanguage: "fr", lifetime: lifetime) { _ in
                lifetime.invalidate()
                return [response("0", text: "Un")]
            }
        }
    }

    @available(macCatalyst 26.0, *)
    @Test @MainActor func taskCancellationAlsoRejectsLateNativeResults() async {
        let task = Task { @MainActor in
            try await AppleNarrationTranslator.translate(["One"], sourceLanguage: "en", targetLanguage: "fr", lifetime: NarrationTranslationLifetime()) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return [response("0", text: "Un")]
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @available(macCatalyst 26.0, *)
    @Test(arguments: [false, true])
    @MainActor func cancellationDuringRetryBackoffPreventsAnotherNativeCall(_ cancelTask: Bool) async {
        let lifetime = NarrationTranslationLifetime()
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        var calls = 0
        var delays: [Duration] = []
        let task = Task { @MainActor in
            defer { entered.continuation.finish() }
            return try await AppleNarrationTranslator.translate(
                ["One"], sourceLanguage: "en", targetLanguage: "fr", lifetime: lifetime,
                sleep: { delay in
                    delays.append(delay)
                    if delays.count == 1 {
                        entered.continuation.yield(())
                        for await _ in release.stream { break }
                    }
                }
            ) { _ in
                calls += 1
                throw TranslationError.internalError
            }
        }
        defer {
            task.cancel()
            entered.continuation.finish()
            release.continuation.finish()
        }
        for await _ in entered.stream { break }
        if cancelTask { task.cancel() } else { lifetime.invalidate() }
        release.continuation.yield(())
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(calls == 1)
        #expect(delays == [.milliseconds(500)])
    }

    @available(macCatalyst 26.0, *)
    @Test @MainActor func cancellationThrownByBackoffPreventsAnotherNativeCall() async {
        var calls = 0
        var delays: [Duration] = []
        await #expect(throws: CancellationError.self) {
            try await AppleNarrationTranslator.translate(
                ["One"], sourceLanguage: "en", targetLanguage: "fr", lifetime: NarrationTranslationLifetime(),
                sleep: { delay in
                    delays.append(delay)
                    throw CancellationError()
                }
            ) { _ in
                calls += 1
                throw TranslationError.internalError
            }
        }
        #expect(calls == 1)
        #expect(delays == [.milliseconds(500)])
    }

    @available(macCatalyst 26.0, *)
    @Test(arguments: [false, true])
    @MainActor func cancellationFencesLateNativeFailuresBeforeBackoff(_ cancelTask: Bool) async {
        let lifetime = NarrationTranslationLifetime()
        var calls = 0
        var sleeps = 0
        let task = Task { @MainActor in
            try await AppleNarrationTranslator.translate(
                ["One"], sourceLanguage: "en", targetLanguage: "fr", lifetime: lifetime,
                sleep: { _ in sleeps += 1 }
            ) { _ in
                calls += 1
                if cancelTask { withUnsafeCurrentTask { $0?.cancel() } } else { lifetime.invalidate() }
                throw TranslationError.internalError
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(calls == 1)
        #expect(sleeps == 0)
    }

    @available(macCatalyst 26.0, *)
    @Test @MainActor func successfulLanguagePreparationCallsConsentOperation() async throws {
        var calls = 0
        try await AppleNarrationTranslator.prepare(lifetime: NarrationTranslationLifetime()) { calls += 1 }
        #expect(calls == 1)
    }

    @available(macCatalyst 26.0, *)
    @Test @MainActor func nativeSessionRejectsOverlapAndDiscardsCancelledCompletion() async {
        let lifetime = NarrationTranslationLifetime()
        let session = NSObject()
        let sessionID = ObjectIdentifier(session)
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let first = Task { @MainActor in
            try await lifetime.withNativeOperation(sessionID: sessionID) {
                entered.continuation.yield(())
                for await _ in release.stream { break }
                return "late native result"
            }
        }
        defer {
            first.cancel()
            entered.continuation.finish()
            release.continuation.finish()
            withExtendedLifetime(session) {}
        }
        for await _ in entered.stream { break }
        var overlappingCallEntered = false
        await #expect(throws: NarrationTranslationError.sessionBusy) {
            try await lifetime.withNativeOperation(sessionID: sessionID) { overlappingCallEntered = true }
        }
        #expect(!overlappingCallEntered)
        lifetime.invalidate()
        release.continuation.yield(())
        await #expect(throws: CancellationError.self) { try await first.value }
        await #expect(throws: CancellationError.self) {
            try await lifetime.withNativeOperation(sessionID: sessionID) { overlappingCallEntered = true }
        }
        #expect(!overlappingCallEntered)
    }

    @available(macCatalyst 26.0, *)
    @Test @MainActor func nativeSessionGateReleasesAfterFailure() async throws {
        let lifetime = NarrationTranslationLifetime()
        let session = NSObject()
        defer { withExtendedLifetime(session) {} }
        await #expect(throws: TranslationError.self) {
            try await lifetime.withNativeOperation(sessionID: ObjectIdentifier(session)) { throw TranslationError.internalError }
        }
        let retried = try await lifetime.withNativeOperation(sessionID: ObjectIdentifier(session)) { true }
        #expect(retried)
    }

    @available(macCatalyst 26.0, *)
    @Test(arguments: [false, true])
    @MainActor func nativeSessionGateCoversRetriesAndFencesLateResults(_ retireBeforeResponse: Bool) async throws {
        let lifetime = NarrationTranslationLifetime()
        let session = NSObject()
        let sessionID = ObjectIdentifier(session)
        let sleeping = AsyncStream<Void>.makeStream()
        let resumeSleep = AsyncStream<Void>.makeStream()
        let nativeEntered = AsyncStream<Void>.makeStream()
        let releaseNative = AsyncStream<Void>.makeStream()
        var calls = 0
        var delays: [Duration] = []
        let task = Task { @MainActor in
            defer {
                sleeping.continuation.finish()
                nativeEntered.continuation.finish()
            }
            return try await lifetime.withNativeOperation(sessionID: sessionID) {
                try await AppleNarrationTranslator.translate(
                    ["One"], sourceLanguage: "en", targetLanguage: "fr", lifetime: lifetime,
                    sleep: { delay in
                        delays.append(delay)
                        sleeping.continuation.yield(())
                        for await _ in resumeSleep.stream { break }
                    }
                ) { _ in
                    calls += 1
                    if calls == 1 { throw TranslationError.internalError }
                    nativeEntered.continuation.yield(())
                    for await _ in releaseNative.stream { break }
                    return [response("0", text: "Un")]
                }
            }
        }
        defer {
            task.cancel()
            sleeping.continuation.finish()
            resumeSleep.continuation.finish()
            nativeEntered.continuation.finish()
            releaseNative.continuation.finish()
            withExtendedLifetime(session) {}
        }
        for await _ in sleeping.stream { break }
        #expect(calls == 1)
        var overlappingCallEntered = false
        await #expect(throws: NarrationTranslationError.sessionBusy) {
            try await lifetime.withNativeOperation(sessionID: sessionID) { overlappingCallEntered = true }
        }
        resumeSleep.continuation.yield(())
        for await _ in nativeEntered.stream { break }
        #expect(calls == 2)
        await #expect(throws: NarrationTranslationError.sessionBusy) {
            try await lifetime.withNativeOperation(sessionID: sessionID) { overlappingCallEntered = true }
        }
        if retireBeforeResponse { lifetime.invalidate() }
        releaseNative.continuation.yield(())
        if retireBeforeResponse {
            await #expect(throws: CancellationError.self) { try await task.value }
            await #expect(throws: CancellationError.self) {
                try await lifetime.withNativeOperation(sessionID: sessionID) { overlappingCallEntered = true }
            }
        } else {
            #expect(try await task.value == ["Un"])
            let available = try await lifetime.withNativeOperation(sessionID: sessionID) { true }
            #expect(available)
        }
        #expect(!overlappingCallEntered)
        #expect(calls == 2)
        #expect(delays == [.milliseconds(500)])
    }

    @available(macCatalyst 26.0, *)
    @Test @MainActor func aViewLifetimeCannotAdoptAReplacementSession() async throws {
        let lifetime = NarrationTranslationLifetime()
        let first = NSObject()
        let replacement = NSObject()
        defer { withExtendedLifetime((first, replacement)) {} }
        try await lifetime.withNativeOperation(sessionID: ObjectIdentifier(first)) {}
        var replacementEntered = false
        await #expect(throws: CancellationError.self) {
            try await lifetime.withNativeOperation(sessionID: ObjectIdentifier(replacement)) { replacementEntered = true }
        }
        #expect(!replacementEntered)
    }

    @available(macCatalyst 26.0, *)
    @Test @MainActor func retirementIsVisibleOnTheNativeExecutor() async throws {
        let lifetime = NarrationTranslationLifetime()
        try await Task.detached { try lifetime.check() }.value
        lifetime.invalidate()
        await #expect(throws: CancellationError.self) {
            try await Task.detached { try lifetime.check() }.value
        }
    }

    @available(macCatalyst 26.0, *)
    @Test @MainActor func nativeFailuresKeepDownloadAndTranslationErrorsDistinct() async {
        var preparationCalls = 0
        await #expect(throws: NarrationTranslationError.languagePreparationFailed) {
            try await AppleNarrationTranslator.prepare(lifetime: NarrationTranslationLifetime()) {
                preparationCalls += 1
                throw TranslationError.internalError
            }
        }
        #expect(preparationCalls == 1)
        await #expect(throws: NarrationTranslationError.translationFailed) {
            try await AppleNarrationTranslator.translate(
                ["One"], sourceLanguage: "en", targetLanguage: "fr", lifetime: NarrationTranslationLifetime(),
                sleep: { _ in }
            ) { _ in
                throw TranslationError.internalError
            }
        }
    }

    @available(macCatalyst 26.0, *)
    @Test @MainActor func nativeCancellationRemainsCancellation() async {
        var calls = 0
        var sleeps = 0
        await #expect(throws: CancellationError.self) {
            try await AppleNarrationTranslator.prepare(lifetime: NarrationTranslationLifetime()) { throw CancellationError() }
        }
        await #expect(throws: CancellationError.self) {
            try await AppleNarrationTranslator.translate(
                ["One"], sourceLanguage: "en", targetLanguage: "fr", lifetime: NarrationTranslationLifetime(),
                sleep: { _ in sleeps += 1 }
            ) { _ in
                calls += 1
                throw CancellationError()
            }
        }
        #expect(calls == 1)
        #expect(sleeps == 0)
    }

    @available(macCatalyst 26.0, *)
    @Test(arguments: [
        (TranslationError.unsupportedSourceLanguage, NarrationTranslationError.unsupportedPair),
        (.unsupportedTargetLanguage, .unsupportedPair),
        (.unsupportedLanguagePairing, .unsupportedPair),
        (.nothingToTranslate, .emptyInput),
        (.unableToIdentifyLanguage, .translationFailed),
    ])
    @MainActor func nontransientNativeFailuresNeverRetry(_ error: TranslationError, expected: NarrationTranslationError) async {
        var calls = 0
        var sleeps = 0
        await #expect(throws: expected) {
            try await AppleNarrationTranslator.translate(
                ["One"], sourceLanguage: "en", targetLanguage: "fr", lifetime: NarrationTranslationLifetime(),
                sleep: { _ in sleeps += 1 }
            ) { _ in
                calls += 1
                throw error
            }
        }
        #expect(calls == 1)
        #expect(sleeps == 0)
    }

    @available(macCatalyst 26.0, *)
    @Test(arguments: [
        NarrationTranslationError.unsupportedPair, .emptyInput, .invalidResponse, .languagesNotReady,
        .languagePreparationFailed, .translationFailed, .sessionBusy,
    ])
    @MainActor func applicationFailuresKeepTheirTypeWithoutRetrying(_ error: NarrationTranslationError) async {
        var calls = 0
        var sleeps = 0
        await #expect(throws: error) {
            try await AppleNarrationTranslator.translate(
                ["One"], sourceLanguage: "en", targetLanguage: "fr", lifetime: NarrationTranslationLifetime(),
                sleep: { _ in sleeps += 1 }
            ) { _ in
                calls += 1
                throw error
            }
        }
        #expect(calls == 1)
        #expect(sleeps == 0)
    }

    @available(macCatalyst 26.0, *)
    @Test @MainActor func unknownNativeFailureNeverRetries() async {
        var calls = 0
        var sleeps = 0
        await #expect(throws: NarrationTranslationError.translationFailed) {
            try await AppleNarrationTranslator.translate(
                ["One"], sourceLanguage: "en", targetLanguage: "fr", lifetime: NarrationTranslationLifetime(),
                sleep: { _ in sleeps += 1 }
            ) { _ in
                calls += 1
                throw NSError(domain: "NarrationLanguageTests", code: 1)
            }
        }
        #expect(calls == 1)
        #expect(sleeps == 0)
    }

    @available(macCatalyst 26.0, *)
    @Test @MainActor func uninstalledLanguagesNeverRetry() async {
        if #available(iOS 26.0, macCatalyst 26.0, macOS 26.0, *) {
            var calls = 0
            var sleeps = 0
            await #expect(throws: NarrationTranslationError.languagesNotReady) {
                try await AppleNarrationTranslator.translate(
                    ["One"], sourceLanguage: "en", targetLanguage: "fr", lifetime: NarrationTranslationLifetime(),
                    sleep: { _ in sleeps += 1 }
                ) { _ in
                    calls += 1
                    throw TranslationError.notInstalled
                }
            }
            #expect(calls == 1)
            #expect(sleeps == 0)
        }
    }

    @available(macCatalyst 26.0, *)
    @Test @MainActor func alreadyCancelledNativeSessionNeverRetries() async {
        if #available(iOS 26.0, macCatalyst 26.0, macOS 26.0, *) {
            var calls = 0
            var sleeps = 0
            await #expect(throws: CancellationError.self) {
                try await AppleNarrationTranslator.translate(
                    ["One"], sourceLanguage: "en", targetLanguage: "fr", lifetime: NarrationTranslationLifetime(),
                    sleep: { _ in sleeps += 1 }
                ) { _ in
                    calls += 1
                    throw TranslationError.alreadyCancelled
                }
            }
            #expect(calls == 1)
            #expect(sleeps == 0)
        }
    }

    @available(macCatalyst 26.0, *)
    @Test func nativeUnsupportedErrorsAreActionableAndCancellationIsPreserved() {
        for error in [TranslationError.unsupportedSourceLanguage, .unsupportedTargetLanguage, .unsupportedLanguagePairing] {
            #expect(AppleNarrationTranslator.mappedError(error, preparingLanguages: true) as? NarrationTranslationError == .unsupportedPair)
        }
        #expect(AppleNarrationTranslator.mappedError(TranslationError.nothingToTranslate, preparingLanguages: false) as? NarrationTranslationError == .emptyInput)
        #expect(AppleNarrationTranslator.mappedError(CancellationError(), preparingLanguages: true) is CancellationError)
        if #available(iOS 26.0, macCatalyst 26.0, macOS 26.0, *) {
            #expect(AppleNarrationTranslator.mappedError(TranslationError.alreadyCancelled, preparingLanguages: false) is CancellationError)
            #expect(AppleNarrationTranslator.mappedError(TranslationError.notInstalled, preparingLanguages: false) as? NarrationTranslationError == .languagesNotReady)
        }
    }

    @available(macCatalyst 26.0, *)
    private func response(
        _ id: String?, text: String, source: String = "en", target: String = "fr"
    ) -> TranslationSession.Response {
        TranslationSession.Response(
            sourceLanguage: Locale.Language(identifier: source), targetLanguage: Locale.Language(identifier: target),
            sourceText: "Source", targetText: text, clientIdentifier: id
        )
    }
}

#if TRANSLATED_NARRATION
@Suite
struct NarrationPlaybackPresentationTests {
    @Test(arguments: [false, true])
    func repairedVariantWithSameIDReloadsItsAudioAndTimeline(_ isPlaying: Bool) {
        let original = document(text: "Old translation", duration: 12)
        let repaired = document(text: "Corrected translation", duration: 19)
        #expect(original.id == repaired.id)
        #expect(NarrationPlaybackPresentation.action(
            for: repaired, current: original, isPlaying: isPlaying, hasFailure: false
        ) == .load)
    }

    @Test func unchangedRenditionResumesWithoutReloadingOrInterruptingReadAlong() {
        let cached = document()
        #expect(NarrationPlaybackPresentation.action(
            for: cached, current: cached, isPlaying: false, hasFailure: false
        ) == .resume)
        #expect(NarrationPlaybackPresentation.action(
            for: cached, current: cached, isPlaying: true, hasFailure: false
        ) == .readAlong)
    }

    @Test func failedPlaybackOrRejectedStartRequiresAFreshLoad() {
        let cached = document()
        #expect(NarrationPlaybackPresentation.action(
            for: cached, current: cached, isPlaying: false, hasFailure: true
        ) == .load)
        #expect(NarrationPlaybackPresentation.action(
            for: cached, current: nil, isPlaying: true, hasFailure: true
        ) == .load)
    }

    private func document(text: String = "Translated passage", duration: TimeInterval = 12) -> NarrationDocument {
        NarrationDocument(
            id: "same-variant", discourseID: "fixture-discourse", sourceDigest: "same-source",
            selection: NarrationSelection(
                sourceLanguage: "en", targetLanguage: "fr",
                voice: NarrationVoice(id: "fixture-voice", name: "French voice", language: "fr-FR", quality: 1)
            ),
            expectedSegmentCount: 1,
            segments: [NarrationSegment(index: 0, sourceParagraphIndex: 0, text: text,
                                        audioFileName: "0.m4a", duration: duration)],
            audioFileName: "narration.m4a", duration: duration, updatedAt: Date(timeIntervalSince1970: 1)
        )
    }
}
#endif
