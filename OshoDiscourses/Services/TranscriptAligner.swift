import Foundation

/// A recognised word with its position in the audio.
struct RecognizedWord: Equatable, Sendable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

/// Aligns recogniser output to the transcript and reads off paragraph starts.
///
/// Both sequences cover the same speech in the same order, so exact matches of
/// rare word trigrams are reliable landmarks. Trigrams that occur exactly once
/// in each sequence become candidate pairs; the longest chain of pairs that
/// advances through both sequences (a longest increasing subsequence) discards
/// the coincidental ones. A paragraph's start is then read from the first
/// landmark inside it, walked back to its first word at the local speaking
/// rate. Paragraphs with no landmark stay nil and are interpolated by
/// `TranscriptSyncModel` between their neighbours.
enum TranscriptAligner {

    /// Landmarks needed before an alignment is trusted at all; below this the
    /// recogniser most likely heard a different recording or nothing.
    static let minimumLandmarks = 12
    /// Words a paragraph start may be extrapolated back across before the
    /// estimate is judged worse than interpolation.
    static let maximumBackwalk = 40

    struct Landmark: Equatable {
        let transcriptToken: Int
        let wordIndex: Int
    }

    static func paragraphStarts(paragraphs: [Transcript.Paragraph], words: [RecognizedWord]) -> [TimeInterval?] {
        var tokens: [String] = []
        var tokenParagraph: [Int] = []
        for p in paragraphs {
            for token in normalizedTokens(p.text) {
                tokens.append(token)
                tokenParagraph.append(p.index)
            }
        }
        let heard = words.map { normalizedTokens($0.text).joined() }   // one word per entry
        let landmarks = self.landmarks(transcript: tokens, heard: heard)
        guard landmarks.count >= minimumLandmarks else {
            return Array(repeating: nil, count: paragraphs.count)
        }

        // First and last transcript token of each paragraph.
        var firstToken = Array(repeating: Int.max, count: paragraphs.count)
        var lastToken = Array(repeating: -1, count: paragraphs.count)
        for (i, p) in tokenParagraph.enumerated() {
            firstToken[p] = min(firstToken[p], i)
            lastToken[p] = max(lastToken[p], i)
        }

        var starts: [TimeInterval?] = Array(repeating: nil, count: paragraphs.count)
        var cursor = 0
        for p in 0..<paragraphs.count {
            guard lastToken[p] >= 0 else { continue }
            while cursor < landmarks.count, landmarks[cursor].transcriptToken < firstToken[p] { cursor += 1 }
            guard cursor < landmarks.count, landmarks[cursor].transcriptToken <= lastToken[p] else { continue }
            let mark = landmarks[cursor]
            let back = mark.transcriptToken - firstToken[p]
            guard back <= maximumBackwalk else { continue }
            let rate = secondsPerToken(around: cursor, landmarks: landmarks, words: words)
            starts[p] = max(0, words[mark.wordIndex].start - Double(back) * rate)
        }
        return starts
    }

    // MARK: - Landmarks

    /// Trigrams unique in both sequences, filtered to a monotonic chain.
    static func landmarks(transcript: [String], heard: [String]) -> [Landmark] {
        func uniqueTrigrams(_ seq: [String]) -> [String: Int] {
            var positions: [String: Int] = [:]
            var repeated: Set<String> = []
            guard seq.count >= 3 else { return [:] }
            for i in 0...(seq.count - 3) {
                let key = seq[i] + " " + seq[i + 1] + " " + seq[i + 2]
                if positions[key] != nil { repeated.insert(key) } else { positions[key] = i }
            }
            for key in repeated { positions.removeValue(forKey: key) }
            return positions
        }
        let heardIndex = uniqueTrigrams(heard)
        let candidates = uniqueTrigrams(transcript)
            .compactMap { key, t -> Landmark? in
                guard let h = heardIndex[key] else { return nil }
                return Landmark(transcriptToken: t, wordIndex: h)
            }
            .sorted { $0.transcriptToken < $1.transcriptToken }
        return longestIncreasingChain(candidates)
    }

    /// Longest subsequence whose word indices strictly increase (transcript
    /// indices already do). Patience sorting, O(n log n).
    static func longestIncreasingChain(_ marks: [Landmark]) -> [Landmark] {
        guard !marks.isEmpty else { return [] }
        var tails: [Int] = []            // index into marks of the tail of each pile
        var previous = Array(repeating: -1, count: marks.count)
        for (i, m) in marks.enumerated() {
            var lo = 0, hi = tails.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if marks[tails[mid]].wordIndex < m.wordIndex { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0 { previous[i] = tails[lo - 1] }
            if lo == tails.count { tails.append(i) } else { tails[lo] = i }
        }
        var chain: [Landmark] = []
        var i = tails[tails.count - 1]
        while i >= 0 {
            chain.append(marks[i])
            i = previous[i]
        }
        return chain.reversed()
    }

    /// Local speaking rate from the landmarks around `index`.
    private static func secondsPerToken(around index: Int, landmarks: [Landmark], words: [RecognizedWord]) -> TimeInterval {
        let lo = max(0, index - 3), hi = min(landmarks.count - 1, index + 3)
        let a = landmarks[lo], b = landmarks[hi]
        let tokens = b.transcriptToken - a.transcriptToken
        let seconds = words[b.wordIndex].start - words[a.wordIndex].start
        // Osho speaks slowly: ~0.45 s/word is a sane default when the window
        // collapses to a single landmark.
        guard tokens > 0, seconds > 0 else { return 0.45 }
        return min(max(seconds / Double(tokens), 0.15), 1.5)
    }

    // MARK: - Normalisation

    /// Lowercased letters and digits of any script; punctuation, Latin accents
    /// and case differences between the edited text and the recogniser vanish.
    ///
    /// Devanagari vowel signs, virama and nukta are combining marks that carry
    /// meaning (कि vs की, क vs क्), so marks are kept except the Latin
    /// diacritics block, which is what turns "café" into "cafe".
    static func normalizedTokens(_ text: String) -> [String] {
        text.lowercased()
            .decomposedStringWithCanonicalMapping
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map { piece in piece.unicodeScalars.filter(keepsInToken).map { Character($0) } }
            .map { String($0) }
            .filter { !$0.isEmpty }
    }

    private static func keepsInToken(_ scalar: Unicode.Scalar) -> Bool {
        if (0x0300...0x036F).contains(scalar.value) { return false }
        let properties = scalar.properties
        if properties.isAlphabetic || properties.numericType != nil { return true }
        switch properties.generalCategory {
        case .nonspacingMark, .spacingMark: return true
        default: return false
        }
    }
}
