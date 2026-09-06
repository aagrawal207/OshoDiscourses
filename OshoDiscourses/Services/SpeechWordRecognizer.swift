import Foundation
import AVFoundation
import Speech

enum SpeechRecognitionError: LocalizedError {
    case unsupported
    case assetsUnavailable
    case noSpeechRecognized

    var errorDescription: String? {
        switch self {
        case .unsupported: return "Speech sync needs iOS 26 on this device."
        case .assetsUnavailable: return "The speech model for this language could not be installed on this device."
        case .noSpeechRecognized: return "No speech could be recognised in this recording."
        }
    }
}

/// Runs Apple's on-device speech recognition over an audio file and returns
/// every recognised word with its time range.
///
/// iOS 26 ships two recogniser families. `SpeechTranscriber` is the long-form
/// model but speaks only 30 locales, none of them Hindi. `DictationTranscriber`
/// wraps the keyboard-dictation models, which cover 54 locales including
/// `hi_IN`; on an 85-minute Hindi talk it recognised 94% of the transcript's
/// words and aligned 176 of 218 paragraphs, so Hindi goes through it.
@available(iOS 26.0, *)
enum SpeechWordRecognizer {

    enum Engine: Equatable, Sendable {
        case transcriber(Locale)
        case dictation(Locale)

        var locale: Locale {
            switch self {
            case .transcriber(let l), .dictation(let l): return l
            }
        }

        /// Stored with alignments, e.g. "SpeechTranscriber/en_IN".
        var name: String {
            switch self {
            case .transcriber: return "SpeechTranscriber/\(locale.identifier)"
            case .dictation: return "DictationTranscriber/\(locale.identifier)"
            }
        }
    }

    /// The best engine this device has for `language`, or nil if none.
    ///
    /// English prefers `SpeechTranscriber` in Indian English (Osho spoke in
    /// Pune), then any English. Hindi has only the dictation model.
    static func preferredEngine(for language: SeriesInfo.Language) async -> Engine? {
        switch language {
        case .english:
            let supported = await SpeechTranscriber.supportedLocales
            let english = supported.filter { $0.language.languageCode?.identifier == "en" }
            if let india = english.first(where: { $0.region?.identifier == "IN" }) { return .transcriber(india) }
            if let us = english.first(where: { $0.region?.identifier == "US" }) { return .transcriber(us) }
            if let any = english.first { return .transcriber(any) }
            let dictation = await DictationTranscriber.supportedLocales
            return dictation.first { $0.language.languageCode?.identifier == "en" }.map(Engine.dictation)
        case .hindi:
            let dictation = await DictationTranscriber.supportedLocales
            return dictation.first { $0.language.languageCode?.identifier == "hi" }.map(Engine.dictation)
        }
    }

    static func recognizeWords(
        in url: URL,
        engine: Engine,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [RecognizedWord] {
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        switch engine {
        case .transcriber(let locale):
            let module = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [],
                attributeOptions: [.audioTimeRange]
            )
            try await prepareAssets(for: module, locale: locale)
            return try await analyze(file: file, duration: duration, module: module,
                                     results: module.results.map { ($0.text, $0.range) }, progress: progress)
        case .dictation(let locale):
            // Lecture-hall recordings, not a phone held to the mouth.
            let module = DictationTranscriber(
                locale: locale,
                contentHints: [.farField],
                transcriptionOptions: [],
                reportingOptions: [],
                attributeOptions: [.audioTimeRange]
            )
            try await prepareAssets(for: module, locale: locale)
            return try await analyze(file: file, duration: duration, module: module,
                                     results: module.results.map { ($0.text, $0.range) }, progress: progress)
        }
    }

    /// The app must hold a reservation on the locale before it may check or
    /// install that locale's assets ("not subscribed to transcription.en"
    /// otherwise). The model itself is a one-time download; afterwards the
    /// installation request comes back nil.
    private static func prepareAssets(for module: any SpeechModule, locale: Locale) async throws {
        let status = await AssetInventory.status(forModules: [module])
        guard status != .unsupported else { throw SpeechRecognitionError.unsupported }
        if !(await AssetInventory.reservedLocales).contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            try await AssetInventory.reserve(locale: locale)
        }
        if status != .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
    }

    private static func analyze<Results: AsyncSequence & Sendable>(
        file: AVAudioFile,
        duration: TimeInterval,
        module: any SpeechModule,
        results: Results,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [RecognizedWord] where Results.Element == (AttributedString, CMTimeRange) {
        let analyzer = SpeechAnalyzer(modules: [module])

        // Results stream while the analyzer runs, so collect them concurrently.
        let collector = Task<[RecognizedWord], Error> {
            var words: [RecognizedWord] = []
            for try await (text, range) in results {
                words.append(contentsOf: Self.words(in: text))
                if duration > 0 {
                    progress(min(1, range.end.seconds / duration))
                }
            }
            return words
        }

        do {
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw error
        }

        let words = try await collector.value
        guard !words.isEmpty else { throw SpeechRecognitionError.noSpeechRecognized }
        return words.sorted { $0.start < $1.start }
    }

    /// Words from one result. Each attributed run carries the time range of the
    /// audio it came from; a run holding several words shares its span evenly.
    static func words(in text: AttributedString) -> [RecognizedWord] {
        var out: [RecognizedWord] = []
        for run in text.runs {
            guard let range = run.audioTimeRange else { continue }
            let pieces = String(text[run.range].characters)
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
            guard !pieces.isEmpty else { continue }
            let start = range.start.seconds
            let step = max(0, range.duration.seconds) / Double(pieces.count)
            for (i, piece) in pieces.enumerated() {
                out.append(RecognizedWord(text: piece, start: start + step * Double(i), end: start + step * Double(i + 1)))
            }
        }
        return out
    }
}
