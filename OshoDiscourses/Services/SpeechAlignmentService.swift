import Foundation

/// Experimental: recovers paragraph start times for a transcript by running
/// Apple's on-device speech recogniser over the downloaded audio and aligning
/// the recognised words to the text.
///
/// English only. `SpeechTranscriber` (iOS 26) has no Hindi model, and the older
/// `SFSpeechRecognizer` supports Hindi only via Apple's servers in one-minute
/// requests, which is neither private nor practical for 100-minute talks. Hindi
/// stays on the text-fraction estimate plus manual anchors.
@Observable
@MainActor
final class SpeechAlignmentService {
    static let shared = SpeechAlignmentService()

    enum Status: Equatable {
        case idle
        /// Downloading or installing the recogniser's language assets.
        case preparingAssets
        /// Fraction of the audio processed so far.
        case listening(progress: Double)
        case aligning
        case done(matched: Int, total: Int)
        case failed(String)

        var isActive: Bool {
            switch self {
            case .preparingAssets, .listening, .aligning: return true
            default: return false
            }
        }
    }

    private(set) var status: Status = .idle
    /// The discourse the current or last run was for; status applies to it.
    private(set) var discourseID: String?

    private var task: Task<Void, Never>?

    private init() {}

    /// Whether this device can align transcripts in `language` at all.
    nonisolated static func isSupported(for language: SeriesInfo.Language) -> Bool {
        guard language == .english else { return false }
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// Start (or restart) alignment for a discourse. Results land in
    /// `TranscriptStateService` as a `TranscriptAlignment`; status reports
    /// progress meanwhile. A run already going for the same discourse is kept.
    func align(discourseID: String, transcript: Transcript, audioURL: URL) {
        if self.discourseID == discourseID, status.isActive { return }
        cancel()
        self.discourseID = discourseID
        status = .preparingAssets
        print("[SpeechAlignment] start \(discourseID) file=\(audioURL.lastPathComponent)")
        task = Task { [weak self] in
            guard let self else { return }
            do {
                guard #available(iOS 26.0, *) else { throw AlignmentError.unsupported }
                // Whichever English the installed model speaks; the recordings
                // are Indian English but the acoustic model is shared.
                guard let locale = await SpeechWordRecognizer.preferredLocale() else {
                    throw AlignmentError.assetsUnavailable
                }
                let started = Date()
                let words = try await SpeechWordRecognizer.recognizeWords(in: audioURL, locale: locale) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.discourseID == discourseID, !Task.isCancelled else { return }
                        self.status = .listening(progress: progress)
                    }
                }
                try Task.checkCancellation()
                print("[SpeechAlignment] recognised \(words.count) words in \(Int(Date().timeIntervalSince(started)))s")
                status = .aligning
                let starts = await Task.detached(priority: .userInitiated) {
                    TranscriptAligner.paragraphStarts(paragraphs: transcript.paragraphs, words: words)
                }.value
                try Task.checkCancellation()
                let alignment = TranscriptAlignment(starts: starts, createdAt: Date(), engine: "SpeechTranscriber/\(locale.identifier)")
                TranscriptStateService.shared.setAlignment(discourseID: discourseID, alignment: alignment, paragraphCount: transcript.paragraphs.count)
                status = .done(matched: alignment.matchedCount, total: starts.count)
                print("[SpeechAlignment] done: \(alignment.matchedCount)/\(starts.count) paragraphs matched")
            } catch is CancellationError {
                if self.discourseID == discourseID { status = .idle }
            } catch {
                print("[SpeechAlignment] failed: \(error)")
                status = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if status.isActive { status = .idle }
    }

    enum AlignmentError: LocalizedError {
        case unsupported
        case assetsUnavailable
        case noSpeechRecognized

        var errorDescription: String? {
            switch self {
            case .unsupported: return "Speech sync needs iOS 26 and an English discourse."
            case .assetsUnavailable: return "The English speech model could not be installed on this device."
            case .noSpeechRecognized: return "No speech could be recognised in this recording."
            }
        }
    }
}
