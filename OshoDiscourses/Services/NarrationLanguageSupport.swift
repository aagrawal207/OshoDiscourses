import Foundation
import Translation
import os

enum NarrationTranslationStrategy: String, Equatable, Sendable {
    case standard
    case highFidelity
}

@available(macCatalyst 26.0, *)
struct NarrationTranslationSupport: Equatable, Sendable {
    let strategy: NarrationTranslationStrategy
    let status: LanguageAvailability.Status
}

@available(macCatalyst 26.0, *)
struct NarrationLanguageOption: Identifiable, Equatable, Sendable {
    let id: String
    let support: NarrationTranslationSupport
    let voices: [NarrationVoice]

    var displayName: String { NarrationLanguageSupport.displayName(for: id) }
}

enum NarrationLanguageSupport {
    private static let log = Logger(subsystem: "com.agraabhi.oshodiscourses", category: "NarrationTranslation")

    static func sourceLanguage(for language: SeriesInfo.Language) -> String {
        switch language {
        case .english: return "en"
        case .hindi: return "hi"
        }
    }

    static func displayName(for identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    static func isSameLanguage(_ first: String, _ second: String) -> Bool {
        let firstCode = Locale.Language(identifier: first).languageCode
        let secondCode = Locale.Language(identifier: second).languageCode
        return firstCode != nil && firstCode == secondCode
    }

    // Maximization distinguishes voices such as zh-CN (Hans) and zh-TW (Hant),
    // including when the voice's BCP-47 tag specifies a region but no script.
    static func languageAndScript(for identifier: String) -> String {
        let language = Locale.Language(identifier: identifier)
        return [language.languageCode?.identifier, language.script?.identifier]
            .compactMap { $0?.lowercased() }
            .joined(separator: "-")
    }

    static func compatibleVoices(_ voices: [NarrationVoice], targetLanguage: String) -> [NarrationVoice] {
        let key = languageAndScript(for: targetLanguage)
        guard !key.isEmpty else { return [] }
        var seen = Set<String>()
        return voices.filter {
            languageAndScript(for: $0.language) == key && seen.insert($0.id).inserted
        }.sorted {
            if $0.quality != $1.quality { return $0.quality > $1.quality }
            if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return $0.id < $1.id
        }
    }

    @available(macCatalyst 26.0, *)
    static func preferredSupport(
        highFidelity: LanguageAvailability.Status?,
        standard: LanguageAvailability.Status
    ) -> NarrationTranslationSupport? {
        if let highFidelity, highFidelity == .installed || highFidelity == .supported {
            return NarrationTranslationSupport(strategy: .highFidelity, status: highFidelity)
        }
        if standard == .installed || standard == .supported {
            return NarrationTranslationSupport(strategy: .standard, status: standard)
        }
        return nil
    }

    // Translation's availability object isn't Sendable. Keep it local to these
    // nonisolated async calls and return only value types to the view's actor.
    @available(macCatalyst 26.0, *)
    static func availableLanguages(sourceLanguage: String, voices: [NarrationVoice]) async throws -> [NarrationLanguageOption] {
        #if DEBUG
        // Simulator UI fixtures replace availability only; they never translate or invent installed voices.
        if ProcessInfo.processInfo.arguments.contains("-debugNarrationOptions") {
            return ["en", "hi", "fr", "es", "ja"].filter { !isSameLanguage($0, sourceLanguage) }.map {
                NarrationLanguageOption(id: $0, support: .init(strategy: .standard, status: .installed),
                                        voices: compatibleVoices(voices, targetLanguage: $0))
            }
        }
        #endif
        let standard = standardAvailability()
        let highFidelity = highFidelityAvailability()
        var languages = await standard.supportedLanguages
        try Task.checkCancellation()
        if let highFidelity {
            languages += await highFidelity.supportedLanguages
            try Task.checkCancellation()
        }

        return try await availableLanguages(sourceLanguage: sourceLanguage, voices: voices, candidates: languages) { target in
            try await support(from: sourceLanguage, to: target, standard: standard, highFidelity: highFidelity)
        }
    }

    @available(macCatalyst 26.0, *)
    static func availableLanguages(
        sourceLanguage: String, voices: [NarrationVoice], candidates: [Locale.Language],
        checkSupport: (String) async throws -> NarrationTranslationSupport?
    ) async throws -> [NarrationLanguageOption] {
        try Task.checkCancellation()
        var seen = Set<String>()
        var options: [NarrationLanguageOption] = []
        for language in candidates {
            try Task.checkCancellation()
            let identifier = language.minimalIdentifier
            guard !isSameLanguage(sourceLanguage, identifier),
                  seen.insert(languageAndScript(for: identifier)).inserted else { continue }
            let support = try await checkSupport(identifier)
            try Task.checkCancellation()
            if let support {
                options.append(NarrationLanguageOption(
                    id: identifier, support: support,
                    voices: compatibleVoices(voices, targetLanguage: identifier)
                ))
            }
        }
        if options.isEmpty {
            log.info("Availability outcome=unsupported")
        } else if options.allSatisfy({ $0.voices.isEmpty }) {
            log.info("Availability outcome=noVoices")
        } else {
            log.info("Availability outcome=available")
        }
        return options.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    @available(macCatalyst 26.0, *)
    static func support(from source: String, to target: String) async throws -> NarrationTranslationSupport? {
        try await support(
            from: source, to: target,
            standard: standardAvailability(), highFidelity: highFidelityAvailability()
        )
    }

    @available(macCatalyst 26.0, *)
    static func configuration(
        source: String, target: String, strategy: NarrationTranslationStrategy
    ) throws -> TranslationSession.Configuration {
        guard !isSameLanguage(source, target) else { throw NarrationTranslationError.unsupportedPair }
        let sourceLanguage = Locale.Language(identifier: source)
        let targetLanguage = Locale.Language(identifier: target)
        if #available(iOS 26.4, macCatalyst 26.4, macOS 26.4, *) {
            return TranslationSession.Configuration(
                source: sourceLanguage, target: targetLanguage,
                preferredStrategy: strategy == .highFidelity ? .highFidelity : .lowLatency
            )
        }
        guard strategy == .standard else { throw NarrationTranslationError.unsupportedPair }
        return TranslationSession.Configuration(source: sourceLanguage, target: targetLanguage)
    }

    @available(macCatalyst 26.0, *)
    private static func standardAvailability() -> LanguageAvailability {
        if #available(iOS 26.4, macCatalyst 26.4, macOS 26.4, *) {
            return LanguageAvailability(preferredStrategy: .lowLatency)
        }
        return LanguageAvailability()
    }

    @available(macCatalyst 26.0, *)
    private static func highFidelityAvailability() -> LanguageAvailability? {
        if #available(iOS 26.4, macCatalyst 26.4, macOS 26.4, *) {
            return LanguageAvailability(preferredStrategy: .highFidelity)
        }
        return nil
    }

    @available(macCatalyst 26.0, *)
    private static func support(
        from source: String, to target: String,
        standard: LanguageAvailability, highFidelity: LanguageAvailability?
    ) async throws -> NarrationTranslationSupport? {
        try Task.checkCancellation()
        guard !isSameLanguage(source, target) else { return nil }
        let sourceLanguage = Locale.Language(identifier: source)
        let targetLanguage = Locale.Language(identifier: target)
        var highFidelityStatus: LanguageAvailability.Status?
        if let highFidelity {
            highFidelityStatus = await highFidelity.status(from: sourceLanguage, to: targetLanguage)
            try Task.checkCancellation()
        }
        if let support = preferredSupport(highFidelity: highFidelityStatus, standard: .unsupported) {
            return support
        }
        let status = await standard.status(from: sourceLanguage, to: targetLanguage)
        try Task.checkCancellation()
        return preferredSupport(highFidelity: nil, standard: status)
    }
}
