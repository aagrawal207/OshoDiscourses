import Foundation
import AVFoundation
import Speech

/// Runs Apple's on-device `SpeechTranscriber` over an audio file and returns
/// every recognised word with its time range.
@available(iOS 26.0, *)
enum SpeechWordRecognizer {

    /// Locale to transcribe with: Indian English when the model ships it (the
    /// recordings are Osho speaking in Pune), otherwise any installed English.
    static func preferredLocale() async -> Locale? {
        let supported = await SpeechTranscriber.supportedLocales
        let installed = await SpeechTranscriber.installedLocales
        print("[SpeechAlignment] supported=\(supported.map { $0.identifier(.bcp47) }) installed=\(installed.map { $0.identifier(.bcp47) })")
        let english = supported.filter { $0.language.languageCode?.identifier == "en" }
        if let india = english.first(where: { $0.region?.identifier == "IN" }) { return india }
        if let us = english.first(where: { $0.region?.identifier == "US" }) { return us }
        return english.first
    }

    static func recognizeWords(
        in url: URL,
        locale: Locale,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [RecognizedWord] {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        // The app must hold a reservation on the locale before it may check or
        // install that locale's assets ("not subscribed to transcription.en"
        // otherwise). The model itself is a one-time download; afterwards the
        // installation request comes back nil.
        let status = await AssetInventory.status(forModules: [transcriber])
        guard status != .unsupported else { throw SpeechAlignmentService.AlignmentError.unsupported }
        if !(await AssetInventory.reservedLocales).contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            try await AssetInventory.reserve(locale: locale)
        }
        if status != .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Results stream while the analyzer runs, so collect them concurrently.
        let collector = Task<[RecognizedWord], Error> {
            var words: [RecognizedWord] = []
            for try await result in transcriber.results {
                words.append(contentsOf: Self.words(in: result.text))
                if duration > 0 {
                    progress(min(1, result.range.end.seconds / duration))
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
        guard !words.isEmpty else { throw SpeechAlignmentService.AlignmentError.noSpeechRecognized }
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
