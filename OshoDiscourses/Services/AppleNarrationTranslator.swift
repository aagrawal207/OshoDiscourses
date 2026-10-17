import Foundation
// Translation omits Sendable/isolation annotations. The session-bound lifetime
// below admits only one awaited native call; cancellation never calls the session.
@preconcurrency import Translation
import os

enum NarrationTranslationError: LocalizedError, Equatable {
    case unsupportedPair
    case emptyInput
    case invalidResponse
    case languagesNotReady
    case languagePreparationFailed
    case translationFailed
    case sessionBusy

    var errorDescription: String? {
        switch self {
        case .unsupportedPair:
            return "Apple Translation doesn't support this language pair on this device. Choose another language or check availability again."
        case .emptyInput:
            return "The source transcript contains no text to translate."
        case .invalidResponse:
            return "Apple Translation returned an incomplete or invalid translation. Try translating again."
        case .languagesNotReady:
            return "The translation languages aren't ready. Connect to the internet and try again to allow Apple's language download."
        case .languagePreparationFailed:
            return "Language preparation didn't finish. Allow Apple's language download, check your connection and free storage, then try again."
        case .translationFailed:
            return "Apple Translation couldn't translate the transcript. Check the language downloads and try again. Saved passages are kept."
        case .sessionBusy:
            return "Translation is already running. Wait for it to finish and try again."
        }
    }
}

// An escaping service callback must reject work before touching a session whose
// SwiftUI host has disappeared, even if cancellation arrives between batches.
@MainActor
final class NarrationTranslationLifetime {
    let id = UUID()
    nonisolated var isActive: Bool { validity.withLock { $0 } }
    var ownsServicePreparation = false
    private var sessionID: ObjectIdentifier?
    private var nativeCallInFlight = false
    private nonisolated let validity = OSAllocatedUnfairLock(initialState: true)

    func invalidate() { validity.withLock { $0 = false } }

    nonisolated func check() throws {
        try Task.checkCancellation()
        guard isActive else { throw CancellationError() }
    }

    func withNativeOperation<Output: Sendable>(
        sessionID: ObjectIdentifier, operation: @MainActor () async throws -> Output
    ) async throws -> Output {
        try check()
        guard self.sessionID == nil || self.sessionID == sessionID else { throw CancellationError() }
        guard !nativeCallInFlight else { throw NarrationTranslationError.sessionBusy }
        self.sessionID = sessionID
        nativeCallInFlight = true
        defer { nativeCallInFlight = false }
        let output = try await operation()
        try check()
        return output
    }
}

@available(macCatalyst 26.0, *)
enum AppleNarrationTranslator {
    private static let log = Logger(subsystem: "com.agraabhi.oshodiscourses", category: "NarrationTranslation")

    @MainActor
    static func prepare(using session: TranslationSession, lifetime: NarrationTranslationLifetime) async throws {
        try await lifetime.withNativeOperation(sessionID: ObjectIdentifier(session)) {
            try await prepare(lifetime: lifetime) { try await session.prepareTranslation() }
        }
    }

    @MainActor
    static func prepare(
        lifetime: NarrationTranslationLifetime, operation: @MainActor () async throws -> Void
    ) async throws {
        try lifetime.check()
        do {
            try await operation()
            try lifetime.check()
            log.info("Language preparation outcome=ready")
        } catch {
            try lifetime.check()
            let failure = mappedError(error, preparingLanguages: true)
            if failure is CancellationError {
                log.info("Language preparation outcome=cancelled")
            } else {
                log.error("Language preparation outcome=failed")
            }
            throw failure
        }
    }

    @MainActor
    static func translate(
        _ texts: [String], using session: TranslationSession,
        sourceLanguage: String, targetLanguage: String, lifetime: NarrationTranslationLifetime
    ) async throws -> [String] {
        // Hold the session for the whole batch, including backoff, so retries cannot interleave with other work.
        try await lifetime.withNativeOperation(sessionID: ObjectIdentifier(session)) {
            try await translate(
                texts, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage, lifetime: lifetime
            ) { texts in
                try await nativeResponses(for: texts, using: session, lifetime: lifetime)
            }
        }
    }

    @MainActor
    static func translate(
        _ texts: [String], sourceLanguage: String, targetLanguage: String,
        lifetime: NarrationTranslationLifetime,
        sleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        operation: @MainActor ([String]) async throws -> [TranslationSession.Response]
    ) async throws -> [String] {
        let retryDelays: [Duration] = [.milliseconds(500), .seconds(1)]
        var attempts = 0
        do {
            try lifetime.check()
            guard !NarrationLanguageSupport.isSameLanguage(sourceLanguage, targetLanguage) else {
                throw NarrationTranslationError.unsupportedPair
            }
            let requests = try requests(for: texts)
            while true {
                try lifetime.check()
                attempts += 1
                let responses: [TranslationSession.Response]
                do {
                    responses = try await operation(texts)
                } catch {
                    try lifetime.check()
                    // Only the SDK's internal failure is retryable; unknown errors need explicit recovery.
                    guard case TranslationError.internalError = error, attempts <= retryDelays.count else { throw error }
                    log.info("Translation batch outcome=retrying reason=internalError attempts=\(attempts, privacy: .public) nextAttempt=\(attempts + 1, privacy: .public)")
                    try await sleep(retryDelays[attempts - 1])
                    try lifetime.check()
                    continue
                }
                try lifetime.check()
                let translations = try orderedTranslations(
                    responses, requests: requests, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage
                )
                log.debug("Translation batch outcome=translated attempts=\(attempts, privacy: .public) retries=\(attempts - 1, privacy: .public)")
                return translations
            }
        } catch {
            let failure: Error
            if Task.isCancelled || !lifetime.isActive {
                failure = CancellationError()
            } else if error is NarrationTranslationError {
                failure = error
            } else {
                failure = mappedError(error, preparingLanguages: false)
            }
            let retries = max(0, attempts - 1)
            if failure is CancellationError {
                log.info("Translation batch outcome=cancelled attempts=\(attempts, privacy: .public) retries=\(retries, privacy: .public)")
            } else {
                let outcome = failure as? NarrationTranslationError == .invalidResponse ? "invalidResponse" : "failed"
                let reason: String
                if case TranslationError.internalError = error, attempts > retryDelays.count {
                    reason = "retryExhausted"
                } else {
                    reason = "nonretryable"
                }
                log.error("Translation batch outcome=\(outcome, privacy: .public) reason=\(reason, privacy: .public) attempts=\(attempts, privacy: .public) retries=\(retries, privacy: .public)")
            }
            throw failure
        }
    }

    // Requests stay local to the SDK's nonisolated executor. Only Sendable text
    // and responses cross back to the actor that owns the lifetime gate.
    nonisolated private static func nativeResponses(
        for texts: [String], using session: TranslationSession, lifetime: NarrationTranslationLifetime
    ) async throws -> [TranslationSession.Response] {
        try lifetime.check()
        let requests = try requests(for: texts)
        try lifetime.check()
        let responses = try await session.translations(from: requests)
        try lifetime.check()
        return responses
    }

    static func requests(for texts: [String]) throws -> [TranslationSession.Request] {
        guard !texts.isEmpty,
              texts.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw NarrationTranslationError.emptyInput
        }
        return texts.enumerated().map {
            TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
        }
    }

    static func orderedTranslations(
        _ responses: [TranslationSession.Response], requests: [TranslationSession.Request],
        sourceLanguage: String, targetLanguage: String
    ) throws -> [String] {
        guard !requests.isEmpty, responses.count == requests.count else {
            throw NarrationTranslationError.invalidResponse
        }
        let identifiers = requests.compactMap(\.clientIdentifier)
        let expected = Set(identifiers)
        guard identifiers.count == requests.count, expected.count == requests.count else {
            throw NarrationTranslationError.invalidResponse
        }
        var translations: [String: String] = [:]
        for response in responses {
            guard let identifier = response.clientIdentifier,
                  expected.contains(identifier), translations[identifier] == nil,
                  !response.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  NarrationLanguageSupport.languageAndScript(for: response.sourceLanguage.minimalIdentifier)
                    == NarrationLanguageSupport.languageAndScript(for: sourceLanguage),
                  NarrationLanguageSupport.languageAndScript(for: response.targetLanguage.minimalIdentifier)
                    == NarrationLanguageSupport.languageAndScript(for: targetLanguage) else {
                throw NarrationTranslationError.invalidResponse
            }
            translations[identifier] = response.targetText
        }
        return try identifiers.map {
            guard let text = translations[$0] else { throw NarrationTranslationError.invalidResponse }
            return text
        }
    }

    static func mappedError(_ error: Error, preparingLanguages: Bool) -> Error {
        if error is CancellationError { return error }
        if case TranslationError.unsupportedSourceLanguage = error { return NarrationTranslationError.unsupportedPair }
        if case TranslationError.unsupportedTargetLanguage = error { return NarrationTranslationError.unsupportedPair }
        if case TranslationError.unsupportedLanguagePairing = error { return NarrationTranslationError.unsupportedPair }
        if case TranslationError.nothingToTranslate = error { return NarrationTranslationError.emptyInput }
        if #available(iOS 26.0, macCatalyst 26.0, macOS 26.0, *) {
            if case TranslationError.alreadyCancelled = error { return CancellationError() }
            if case TranslationError.notInstalled = error { return NarrationTranslationError.languagesNotReady }
        }
        return preparingLanguages
            ? NarrationTranslationError.languagePreparationFailed
            : NarrationTranslationError.translationFailed
    }
}
