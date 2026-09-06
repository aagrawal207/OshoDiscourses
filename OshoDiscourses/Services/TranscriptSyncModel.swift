import Foundation

/// A user-placed correction: "the audio was at `time` while paragraph
/// `paragraph` was being spoken". Stored per discourse and synced.
struct TranscriptAnchor: Codable, Equatable, Hashable, Sendable {
    let paragraph: Int
    let time: TimeInterval
    let createdAt: Date
}

/// Maps playback time to a paragraph and back for a transcript that carries no
/// timestamps of its own.
///
/// The baseline guess is that speech advances through the text at a constant
/// rate, so a paragraph's share of the characters is its share of the duration.
/// Knots refine that: each pins one text position to one time, and the map is
/// linear between neighbouring knots. User anchors become knots at the middle
/// of the anchored paragraph (the listener pressed the button somewhere inside
/// it); speech-alignment results become knots at paragraph starts.
struct TranscriptSyncModel: Sendable {

    struct Knot: Equatable, Sendable {
        /// Character offset from the start of the transcript.
        let position: Double
        let time: TimeInterval
    }

    /// Cumulative character offsets; `starts[i]` is where paragraph i begins and
    /// `starts[count]` is the total length.
    let starts: [Double]
    let duration: TimeInterval
    /// Strictly increasing in both position and time, framed by (0, 0) and
    /// (total, duration).
    let knots: [Knot]

    var paragraphCount: Int { max(0, starts.count - 1) }

    /// Weight floor for a paragraph. A one-line sutra or verse is recited slowly
    /// with a pause around it, so its handful of characters understates its
    /// share of the audio; treating every paragraph as at least this long keeps
    /// the highlight from sprinting through an opening recitation.
    static let minimumWeight: Double = 50

    init(paragraphs: [Transcript.Paragraph], duration: TimeInterval, knots interior: [Knot] = []) {
        var starts: [Double] = [0]
        starts.reserveCapacity(paragraphs.count + 1)
        for p in paragraphs {
            // Whitespace-free length: a verse broken over several short lines
            // shouldn't be weighted by its formatting.
            let characters = Double(p.text.unicodeScalars.filter { !$0.properties.isWhitespace }.count)
            starts.append(starts[starts.count - 1] + max(characters, Self.minimumWeight))
        }
        self.starts = starts
        self.duration = max(0, duration)
        let total = starts[starts.count - 1]
        self.knots = Self.frame(interior, total: total, duration: self.duration)
    }

    /// Knot for a user anchor: the middle of the paragraph maps to the time.
    func knot(for anchor: TranscriptAnchor) -> Knot? {
        guard anchor.paragraph >= 0, anchor.paragraph < paragraphCount else { return nil }
        let mid = (starts[anchor.paragraph] + starts[anchor.paragraph + 1]) / 2
        return Knot(position: mid, time: anchor.time)
    }

    /// Knot for an aligned paragraph start.
    func knot(paragraph: Int, startingAt time: TimeInterval) -> Knot? {
        guard paragraph >= 0, paragraph < paragraphCount else { return nil }
        return Knot(position: starts[paragraph], time: time)
    }

    /// Knots for aligned paragraph starts corrected by the listener's anchors.
    ///
    /// An anchor is the listener saying the alignment is wrong here, so it wins:
    /// aligned starts that contradict it (an earlier paragraph at a later time,
    /// a later paragraph at an earlier time) are dropped, and the map bends to
    /// the anchor between the surviving neighbours.
    func knots(alignedStarts: [TimeInterval?], anchors: [TranscriptAnchor]) -> [Knot] {
        let anchorKnots = anchors.compactMap { knot(for: $0) }
        var result: [Knot] = []
        for (index, start) in alignedStarts.enumerated() {
            guard let start, let k = knot(paragraph: index, startingAt: start) else { continue }
            let contradicted = anchorKnots.contains { a in
                (k.position < a.position && k.time >= a.time) || (k.position > a.position && k.time <= a.time)
            }
            if !contradicted { result.append(k) }
        }
        return result + anchorKnots
    }

    /// Same transcript and duration, with different knots.
    func with(knots interior: [Knot]) -> TranscriptSyncModel {
        TranscriptSyncModel(starts: starts, duration: duration, knots: Self.frame(interior, total: starts[starts.count - 1], duration: duration))
    }

    private init(starts: [Double], duration: TimeInterval, knots: [Knot]) {
        self.starts = starts
        self.duration = duration
        self.knots = knots
    }

    // MARK: - Mapping

    /// Estimated time at which paragraph `index` starts.
    func startTime(ofParagraph index: Int) -> TimeInterval {
        guard paragraphCount > 0 else { return 0 }
        let i = min(max(index, 0), paragraphCount - 1)
        return time(atPosition: starts[i])
    }

    /// The paragraph being spoken at `time`.
    func paragraph(at time: TimeInterval) -> Int {
        guard paragraphCount > 0 else { return 0 }
        let position = self.position(atTime: time)
        // Last paragraph whose start is at or before the position.
        var lo = 0, hi = paragraphCount - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= position { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    func time(atPosition position: Double) -> TimeInterval {
        interpolate(position, from: \.position, to: \.time)
    }

    func position(atTime time: TimeInterval) -> Double {
        interpolate(time, from: \.time, to: \.position)
    }

    private func interpolate(_ x: Double, from: KeyPath<Knot, Double>, to: KeyPath<Knot, Double>) -> Double {
        guard let first = knots.first, let last = knots.last else { return 0 }
        if x <= first[keyPath: from] { return first[keyPath: to] }
        if x >= last[keyPath: from] { return last[keyPath: to] }
        // Knots are few (framing pair plus a handful of anchors); linear scan.
        for i in 1..<knots.count {
            let a = knots[i - 1], b = knots[i]
            guard x <= b[keyPath: from] else { continue }
            let span = b[keyPath: from] - a[keyPath: from]
            guard span > 0 else { return b[keyPath: to] }
            let t = (x - a[keyPath: from]) / span
            return a[keyPath: to] + t * (b[keyPath: to] - a[keyPath: to])
        }
        return last[keyPath: to]
    }

    // MARK: - Knot hygiene

    /// Sort, clamp to the transcript, and add the (0, 0) and (total, duration)
    /// frame. Interior knots must be strictly increasing in both axes; any that
    /// aren't are dropped in favour of the earlier one, which keeps the map
    /// monotonic even if callers hand over contradictory data.
    private static func frame(_ interior: [Knot], total: Double, duration: TimeInterval) -> [Knot] {
        guard total > 0, duration > 0 else { return [Knot(position: 0, time: 0), Knot(position: max(total, 1), time: max(duration, 0))] }
        var result: [Knot] = [Knot(position: 0, time: 0)]
        for k in interior.sorted(by: { $0.position < $1.position }) {
            let position = min(max(k.position, 0), total)
            let time = min(max(k.time, 0), duration)
            guard position > result[result.count - 1].position,
                  time > result[result.count - 1].time,
                  position < total, time < duration else { continue }
            result.append(Knot(position: position, time: time))
        }
        result.append(Knot(position: total, time: duration))
        return result
    }

    // MARK: - Anchor sets

    /// Add an anchor to a set, evicting anything it contradicts: an anchor on
    /// the same paragraph, an earlier paragraph pinned to a later time, or a
    /// later paragraph pinned to an earlier time. The newest anchor is treated
    /// as the truth because the listener just heard it.
    static func inserting(_ anchor: TranscriptAnchor, into anchors: [TranscriptAnchor]) -> [TranscriptAnchor] {
        var kept = anchors.filter { existing in
            if existing.paragraph == anchor.paragraph { return false }
            if existing.paragraph < anchor.paragraph { return existing.time < anchor.time }
            return existing.time > anchor.time
        }
        kept.append(anchor)
        return kept.sorted { $0.paragraph < $1.paragraph }
    }

    /// Order-independent merge for sync: replay the union oldest-first through
    /// `inserting`, so every device that holds the same set of anchors ends up
    /// with the same survivors no matter which arrived when.
    static func merge(_ a: [TranscriptAnchor], _ b: [TranscriptAnchor]) -> [TranscriptAnchor] {
        let union = Set(a).union(b).sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            if $0.paragraph != $1.paragraph { return $0.paragraph < $1.paragraph }
            return $0.time < $1.time
        }
        return union.reduce(into: [TranscriptAnchor]()) { $0 = inserting($1, into: $0) }
    }
}

/// Splits a paragraph into sentences so the reader can mark the one being
/// spoken. Timing inside a paragraph is interpolated from character share, so
/// this is only shown when the paragraph boundaries themselves are aligned.
enum TranscriptSentences {

    /// Full stops, Devanagari dandas and line breaks end a sentence; a run of
    /// terminators ("...", "?!") and any closing quotes after it stay attached.
    private static let terminators: Set<Character> = [".", "!", "?", "।", "॥", "…"]
    private static let trailing: Set<Character> = ["\"", "'", "’", "”", ")", "]", "»"]

    static func ranges(in text: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var start = text.startIndex
        var i = text.startIndex
        func close(at end: String.Index) {
            if start < end { result.append(start..<end) }
            i = end
            while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) }
            start = i
        }
        while i < text.endIndex {
            if text[i] == "\n" { close(at: i); continue }
            guard terminators.contains(text[i]) else { i = text.index(after: i); continue }
            var j = i
            while j < text.endIndex, terminators.contains(text[j]) || trailing.contains(text[j]) { j = text.index(after: j) }
            // A stop glued to the next word ("e.g.", "3.5") does not end anything.
            if j < text.endIndex, !text[j].isWhitespace { i = j; continue }
            close(at: j)
        }
        if start < text.endIndex { result.append(start..<text.endIndex) }
        // A verse number or stray punctuation ("।। 18 ।।") is not a sentence;
        // it belongs to the line before it.
        var merged: [Range<String.Index>] = []
        for range in result {
            if let last = merged.last, !text[range].contains(where: \.isLetter) {
                merged[merged.count - 1] = last.lowerBound..<range.upperBound
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// Which sentence is being spoken when `fraction` (0...1) of the paragraph's
    /// time has elapsed, assuming speech moves through its letters evenly.
    static func index(atFraction fraction: Double, in text: String) -> Int {
        let ranges = ranges(in: text)
        guard ranges.count > 1 else { return 0 }
        let weights = ranges.map { Double(text[$0].unicodeScalars.filter { !$0.properties.isWhitespace }.count) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return 0 }
        let target = min(max(fraction, 0), 1) * total
        var accumulated = 0.0
        for (i, w) in weights.enumerated() {
            accumulated += w
            if target < accumulated { return i }
        }
        return ranges.count - 1
    }
}
