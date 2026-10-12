import Darwin
import Foundation
import Translation

private enum ProbeError: Error {
    case usage
    case downloadCapableSession
}

private enum ProbeStrategy: String, Sendable {
    case lowLatency, highFidelity

    var native: TranslationSession.Strategy {
        self == .highFidelity ? .highFidelity : .lowLatency
    }
}

@main
struct NarrationTranslationProbe {
    // Translation's reference types stay in one nonisolated async owner;
    // neither an actor hop nor a timeout task receives the session.
    @MainActor static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.count >= 2, let strategy = ProbeStrategy(rawValue: arguments[1]) else {
                throw ProbeError.usage
            }
            let deadline = arguments[0] == "inventory" ? 75 : 25
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(deadline)) {
                FileHandle.standardError.write(Data("Probe hard deadline: \(deadline) seconds; exit 124.\n".utf8))
                exit(124)
            }
            emit([
                "event": "environment", "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "processID": ProcessInfo.processInfo.processIdentifier,
                "requestedStrategy": strategy.rawValue,
                "hardDeadlineSeconds": deadline,
                "hosting": "native macOS command-line process; no SwiftUI host",
                "sampleAttribution": "Original philosophical test text, not an Osho quotation.",
                "downloadPolicy": "Only installedSource sessions; never prepareTranslation or a UI download request.",
            ])
            if arguments.count == 2, arguments[0] == "inventory" {
                await inventory(strategy: strategy)
            } else if arguments.count == 4, arguments[0] == "translate" {
                try await translate(strategy: strategy, source: arguments[2], target: arguments[3])
            } else {
                throw ProbeError.usage
            }
        } catch {
            emit(["event": "probe_error", "error": describe(error)])
            FileHandle.standardError.write(Data(
                "Usage: NarrationTranslationProbe inventory lowLatency|highFidelity\n"
                    .appending("       NarrationTranslationProbe translate lowLatency|highFidelity en|hi|es en|hi|es\n").utf8
            ))
            exit(1)
        }
    }

    nonisolated private static func inventory(strategy: ProbeStrategy) async {
        let availability = LanguageAvailability(preferredStrategy: strategy.native)
        emit(["event": "operation_begin", "operation": "LanguageAvailability.supportedLanguages"])
        let languages = await availability.supportedLanguages
        let supported = Array(Set(languages.map(\.minimalIdentifier))).sorted()
        emit(["event": "supported_languages", "languages": supported, "count": supported.count])

        // Include the requested languages even when the framework omits one,
        // so absent support is observed through status rather than inferred.
        let candidates = Array(Set(supported + ["en", "hi", "es"])).sorted()
        let focus = [("en", "hi"), ("hi", "en"), ("en", "es"), ("hi", "es"), ("es", "en"), ("es", "hi")]
        var pairs = focus
        for source in candidates {
            for target in candidates where source != target {
                if !focus.contains(where: { $0.0 == source && $0.1 == target }) {
                    pairs.append((source, target))
                }
            }
        }
        var results: [[String: Any]] = []
        var counts: [String: Int] = [:]
        let start = ContinuousClock.now
        for (source, target) in pairs {
            emit([
                "event": "operation_begin", "operation": "LanguageAvailability.status(from:to:)",
                "sourceLanguage": source, "targetLanguage": target,
            ])
            let status = await availability.status(
                from: Locale.Language(identifier: source), to: Locale.Language(identifier: target)
            )
            let label = name(status)
            let row: [String: Any] = [
                "sourceLanguage": source, "targetLanguage": target, "status": label,
                "sourceListedAsSupported": supported.contains(source),
                "targetListedAsSupported": supported.contains(target),
            ]
            emit(row.merging(["event": "pair_status"]) { _, new in new })
            results.append(row)
            counts[label, default: 0] += 1
        }
        emit([
            "event": "completed", "operation": "inventory", "outcome": "completed",
            "requestedStrategy": strategy.rawValue,
            "reportedPreferredStrategy": name(availability.preferredStrategy),
            "supportedLanguages": supported, "candidateLanguages": candidates,
            "scope": "All directed distinct-identifier pairs among supportedLanguages plus en, hi, es.",
            "pairCount": results.count, "statusCounts": counts, "pairs": results,
            "elapsedSeconds": seconds(start.duration(to: .now)),
            "interpretation": "Availability is the framework's report to this CLI, not proof of successful inference or the selected model.",
        ])
    }

    nonisolated private static func translate(strategy: ProbeStrategy, source: String, target: String) async throws {
        let samples = [
            "en": "Notice a thought without holding on to it. A quiet moment can make room for kindness.",
            "hi": "किसी विचार को पकड़कर रखे बिना उसे देखें। एक शांत क्षण करुणा के लिए जगह बना सकता है।",
            "es": "Observa un pensamiento sin aferrarte a él. Un momento de calma puede dar espacio a la bondad.",
        ]
        guard let text = samples[source], samples[target] != nil, source != target else { throw ProbeError.usage }
        let sourceLanguage = Locale.Language(identifier: source)
        let targetLanguage = Locale.Language(identifier: target)
        let availability = LanguageAvailability(preferredStrategy: strategy.native)
        var report: [String: Any] = [
            "event": "completed", "operation": "translate", "requestedStrategy": strategy.rawValue,
            "requestedSourceLanguage": source, "requestedTargetLanguage": target, "sourceText": text,
            "sampleAttribution": "Original philosophical test text, not an Osho quotation.",
            "initializer": "TranslationSession(installedSource:target:preferredStrategy:)",
        ]
        emit(["event": "operation_begin", "operation": "LanguageAvailability.status(from:to:)"])
        let status = await availability.status(from: sourceLanguage, to: targetLanguage)
        report["availabilityBeforeTranslation"] = name(status)
        emit(["event": "pair_status", "sourceLanguage": source, "targetLanguage": target, "status": name(status)])

        let session = TranslationSession(
            installedSource: sourceLanguage, target: targetLanguage, preferredStrategy: strategy.native
        )
        defer { session.cancel() }
        report["canRequestDownloads"] = session.canRequestDownloads
        report["reportedPreferredStrategy"] = name(session.preferredStrategy)
        emit([
            "event": "session_created", "canRequestDownloads": session.canRequestDownloads,
            "reportedPreferredStrategy": name(session.preferredStrategy),
        ])
        guard !session.canRequestDownloads else { throw ProbeError.downloadCapableSession }
        emit(["event": "operation_begin", "operation": "TranslationSession.isReady"])
        let ready = await session.isReady
        report["isReady"] = ready
        report["attemptKind"] = status == .installed ? "installed-pair translation" : "installed-only negative capability check"
        emit(["event": "session_ready", "isReady": ready])

        // An installed-only session cannot present a download prompt; attempting
        // an unavailable pair records Apple's actual error rather than a fake.
        emit(["event": "operation_begin", "operation": "TranslationSession.translate(_:)", "sourceText": text])
        let start = ContinuousClock.now
        do {
            let response = try await session.translate(text)
            report["responseSourceLanguage"] = response.sourceLanguage.minimalIdentifier
            report["responseTargetLanguage"] = response.targetLanguage.minimalIdentifier
            report["responseSourceText"] = response.sourceText
            report["targetText"] = response.targetText
            let valid = !response.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && response.sourceLanguage.languageCode == sourceLanguage.languageCode
                && response.targetLanguage.languageCode == targetLanguage.languageCode
            report["outcome"] = valid ? "translated" : "invalid-native-response"
            report["responseValidated"] = valid
        } catch {
            report["outcome"] = "native-error"
            report["error"] = describe(error)
        }
        report["elapsedSeconds"] = seconds(start.duration(to: .now))
        emit(report)
    }

    nonisolated private static func describe(_ error: Error) -> [String: Any] {
        let nsError = error as NSError
        var result: [String: Any] = [
            "swiftType": String(reflecting: type(of: error)), "description": String(describing: error),
            "domain": nsError.domain, "code": nsError.code, "localizedDescription": nsError.localizedDescription,
        ]
        let category: String
        switch error {
        case TranslationError.notInstalled: category = "TranslationError.notInstalled"
        case TranslationError.unsupportedSourceLanguage: category = "TranslationError.unsupportedSourceLanguage"
        case TranslationError.unsupportedTargetLanguage: category = "TranslationError.unsupportedTargetLanguage"
        case TranslationError.unsupportedLanguagePairing: category = "TranslationError.unsupportedLanguagePairing"
        case TranslationError.unableToIdentifyLanguage: category = "TranslationError.unableToIdentifyLanguage"
        case TranslationError.nothingToTranslate: category = "TranslationError.nothingToTranslate"
        case TranslationError.alreadyCancelled: category = "TranslationError.alreadyCancelled"
        case TranslationError.internalError: category = "TranslationError.internalError"
        default: category = "unclassified"
        }
        result["translationError"] = category
        if let reason = nsError.localizedFailureReason { result["failureReason"] = reason }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            result["underlyingError"] = [
                "domain": underlying.domain, "code": underlying.code,
                "localizedDescription": underlying.localizedDescription,
            ]
        }
        return result
    }

    nonisolated private static func name(_ status: LanguageAvailability.Status) -> String {
        switch status {
        case .installed: "installed"
        case .supported: "supported"
        case .unsupported: "unsupported"
        @unknown default: "unknown"
        }
    }

    nonisolated private static func name(_ strategy: TranslationSession.Strategy) -> String {
        if strategy == .highFidelity { return "highFidelity" }
        if strategy == .lowLatency { return "lowLatency" }
        return "unknown"
    }

    nonisolated private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    nonisolated private static func emit(_ object: [String: Any]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            FileHandle.standardOutput.write(data + Data([0x0a]))
        } catch {
            FileHandle.standardError.write(Data("Unable to encode probe evidence: \(error)\n".utf8))
            exit(1)
        }
    }
}
