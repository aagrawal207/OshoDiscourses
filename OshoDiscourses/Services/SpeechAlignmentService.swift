import Foundation

/// Recovers paragraph start times for a transcript by running Apple's
/// on-device speech recogniser over the downloaded audio and aligning the
/// recognised words to the text. Used for discourses the shipped
/// `AlignmentCatalog` does not cover.
///
/// iOS 26 only: it is the first release with an offline recogniser that
/// accepts a whole file. Below it, `SFSpeechRecognizer` transcribes Hindi only
/// through Apple's servers in one-minute requests, which is neither private nor
/// practical for 100-minute talks.
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

    /// Whether this device can align transcripts in `language` at all. Both
    /// catalog languages have an on-device model on iOS 26.
    nonisolated static func isSupported(for language: SeriesInfo.Language) -> Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// Start (or restart) alignment for a discourse. Results land in
    /// `TranscriptStateService` as a `TranscriptAlignment`; status reports
    /// progress meanwhile. A run already going for the same discourse is kept.
    func align(discourseID: String, transcript: Transcript, language: SeriesInfo.Language, audioURL: URL) {
        if self.discourseID == discourseID, status.isActive { return }
        cancel()
        self.discourseID = discourseID
        status = .preparingAssets
        print("[SpeechAlignment] start \(discourseID) file=\(audioURL.lastPathComponent)")
        task = Task { [weak self] in
            guard let self else { return }
            do {
                guard #available(iOS 26.0, *) else { throw SpeechRecognitionError.unsupported }
                guard let engine = await SpeechWordRecognizer.preferredEngine(for: language) else {
                    throw SpeechRecognitionError.assetsUnavailable
                }
                let started = Date()
                let words = try await SpeechWordRecognizer.recognizeWords(in: audioURL, engine: engine) { [weak self] progress in
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
                let alignment = TranscriptAlignment(starts: starts, createdAt: Date(), engine: engine.name)
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
}
