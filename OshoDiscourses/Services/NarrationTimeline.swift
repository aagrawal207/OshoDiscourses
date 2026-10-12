import Foundation

/// Where each transcript paragraph falls in the original recording.
struct NarrationOriginalTiming: Equatable, Sendable {
    /// Original start time per paragraph, keyed by `Transcript.Paragraph.index`, plus the recording length.
    let starts: [Int: TimeInterval]
    let duration: TimeInterval

    /// Nil when there is no shipped alignment matching this transcript's paragraph count.
    static func make(transcript: Transcript, alignment: AlignmentCatalog.Entry?) -> NarrationOriginalTiming? {
        let paragraphs = transcript.paragraphs
        guard let alignment, !paragraphs.isEmpty,
              alignment.paragraphCount == paragraphs.count, alignment.starts.count == paragraphs.count,
              alignment.duration.isFinite, alignment.duration > 0
        else { return nil }
        // Same construction as the reader, minus anchors: anchors belong to one listener's
        // file, while this timing must hold without the original audio.
        let base = TranscriptSyncModel(paragraphs: paragraphs, duration: alignment.duration)
        let model = base.with(knots: base.knots(alignedStarts: alignment.starts, anchors: []))
        var times = paragraphs.indices.map { model.startTime(ofParagraph: $0) }
        // The sync model pins paragraph 0 to time 0; the aligned start keeps the
        // opening silence out of the first paragraph's span.
        if let first = alignment.starts[0], first.isFinite, first > 0,
           first < (times.count > 1 ? times[1] : alignment.duration) {
            times[0] = first
        }
        var starts: [Int: TimeInterval] = [:]
        var previous: TimeInterval = 0
        for (paragraph, time) in zip(paragraphs, times) where starts[paragraph.index] == nil {
            previous = min(max(time.isFinite ? time : previous, previous), alignment.duration)
            starts[paragraph.index] = previous
        }
        return NarrationOriginalTiming(starts: starts, duration: alignment.duration)
    }

    static func make(transcript: Transcript) -> NarrationOriginalTiming? {
        make(transcript: transcript, alignment: AlignmentCatalog.entry(for: transcript.discourseID))
    }

    /// Seconds from this paragraph's start to the next paragraph's start (or the end).
    func duration(ofParagraph index: Int) -> TimeInterval? {
        guard let start = starts[index], start.isFinite else { return nil }
        let next = starts.keys.filter { $0 > index }.min().flatMap { starts[$0] } ?? duration
        guard next.isFinite else { return nil }
        return max(0, next - start)
    }
}

enum NarrationPacingTargets {
    /// Target seconds for each chunk, splitting a paragraph's duration across its chunks by character count.
    /// Nil entries where no timing is known. Chunks are given in order.
    static func durations(chunks: [(sourceParagraphIndex: Int, characters: Int)], timing: NarrationOriginalTiming?) -> [TimeInterval?] {
        guard let timing else { return chunks.map { _ in nil } }
        var characters: [Int: Int] = [:]
        var counts: [Int: Int] = [:]
        for chunk in chunks {
            characters[chunk.sourceParagraphIndex, default: 0] += max(0, chunk.characters)
            counts[chunk.sourceParagraphIndex, default: 0] += 1
        }
        return chunks.map { chunk in
            guard let total = timing.duration(ofParagraph: chunk.sourceParagraphIndex) else { return nil }
            let paragraphCharacters = characters[chunk.sourceParagraphIndex] ?? 0
            guard paragraphCharacters > 0 else {
                return total / Double(max(1, counts[chunk.sourceParagraphIndex] ?? 1))
            }
            return total * Double(max(0, chunk.characters)) / Double(paragraphCharacters)
        }
    }
}

/// Piecewise-linear correspondence between original and translated time, anchored at paragraph starts.
struct NarrationTimeline: Sendable {

    private struct Point: Sendable {
        let original: TimeInterval
        let translated: TimeInterval
    }

    /// Strictly increasing on both axes; the first is at translated 0 and the last
    /// is the end of the available translated audio.
    private let points: [Point]
    private let reachesRecordingEnd: Bool

    /// Nil if segments are empty, no paragraph of them has timing, or the
    /// translated or original span is empty.
    /// Pass `lastParagraphComplete: false` for a narration still being prepared: its last paragraph
    /// may have only some chunks, so mapping stops at that paragraph's start.
    init?(segments: [NarrationSegment], timing: NarrationOriginalTiming, lastParagraphComplete: Bool = true) {
        var runs: [(paragraph: Int, translatedStart: TimeInterval)] = []
        var translatedEnd: TimeInterval = 0
        for segment in segments {
            if runs.last?.paragraph != segment.sourceParagraphIndex {
                runs.append((segment.sourceParagraphIndex, translatedEnd))
            }
            if segment.duration.isFinite, segment.duration > 0 { translatedEnd += segment.duration }
        }
        if !lastParagraphComplete, let partial = runs.popLast() { translatedEnd = partial.translatedStart }
        // Untimed paragraphs fold into the timed one before them, matching how
        // `duration(ofParagraph:)` measures to the next timed start.
        let timed = runs.filter { timing.starts[$0.paragraph]?.isFinite == true }
        guard let last = timed.last, let lastStart = timing.starts[last.paragraph],
              let lastSpan = timing.duration(ofParagraph: last.paragraph)
        else { return nil }

        var points: [Point] = []
        for (i, run) in timed.enumerated() {
            guard let original = timing.starts[run.paragraph] else { continue }
            // Leading untimed paragraphs have no original place, so translated 0 joins the first timed one.
            let point = Point(original: original, translated: i == 0 ? 0 : run.translatedStart)
            if let previous = points.last, point.original <= previous.original || point.translated <= previous.translated { continue }
            points.append(point)
        }
        let end = Point(original: lastStart + lastSpan, translated: translatedEnd)
        while let previous = points.last, end.original <= previous.original || end.translated <= previous.translated {
            points.removeLast()
        }
        guard !points.isEmpty else { return nil }
        points.append(end)
        self.points = points
        reachesRecordingEnd = end.original >= timing.duration
    }

    /// Nil beyond the translated paragraphs available.
    func translatedTime(forOriginal time: TimeInterval) -> TimeInterval? {
        guard time.isFinite, let first = points.first, let last = points.last else { return nil }
        if time <= first.original { return first.translated }
        if time >= last.original {
            return time == last.original || reachesRecordingEnd ? last.translated : nil
        }
        return Self.interpolate(time, in: points, from: \.original, to: \.translated)
    }

    func originalTime(forTranslated time: TimeInterval) -> TimeInterval? {
        guard time.isFinite, let first = points.first, let last = points.last else { return nil }
        if time <= first.translated { return first.original }
        if time > last.translated { return nil }
        return Self.interpolate(time, in: points, from: \.translated, to: \.original)
    }

    /// `x` lies strictly inside the points' range on the `from` axis.
    private static func interpolate(_ x: Double, in points: [Point], from: KeyPath<Point, Double>, to: KeyPath<Point, Double>) -> Double {
        var lo = 0, hi = points.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if points[mid][keyPath: from] <= x { lo = mid } else { hi = mid }
        }
        let a = points[lo], b = points[hi]
        let span = b[keyPath: from] - a[keyPath: from]
        guard span > 0 else { return a[keyPath: to] }
        return a[keyPath: to] + (x - a[keyPath: from]) / span * (b[keyPath: to] - a[keyPath: to])
    }
}
