import Foundation
import Testing
@testable import OshoDiscourses

struct NarrationOriginalTimingTests {

    static func transcript(_ lengths: [Int], firstIndex: Int = 0, id: String = "x") -> Transcript {
        Transcript(
            discourseID: id, sourceID: "y", fetchedAt: Date(timeIntervalSince1970: 0),
            paragraphs: lengths.enumerated().map { i, n in
                Transcript.Paragraph(index: firstIndex + i, text: String(repeating: "a", count: n), isEmphasis: false)
            }
        )
    }

    @Test func matchedStartsBecomeParagraphStarts() throws {
        let entry = AlignmentCatalog.Entry(paragraphCount: 3, duration: 300, starts: [0, 100, 200])
        let timing = try #require(NarrationOriginalTiming.make(transcript: Self.transcript([100, 100, 100]), alignment: entry))
        #expect(timing.duration == 300)
        #expect(abs(timing.starts[0]! - 0) < 1e-9)
        #expect(abs(timing.starts[1]! - 100) < 1e-9)
        #expect(abs(timing.starts[2]! - 200) < 1e-9)
        #expect(abs(timing.duration(ofParagraph: 2)! - 100) < 1e-9)
        #expect(timing.duration(ofParagraph: 3) == nil)
    }

    @Test func unmatchedStartsAreInterpolated() throws {
        let entry = AlignmentCatalog.Entry(paragraphCount: 3, duration: 300, starts: [0, nil, 200])
        let timing = try #require(NarrationOriginalTiming.make(transcript: Self.transcript([100, 100, 100]), alignment: entry))
        #expect(abs(timing.starts[1]! - 100) < 1e-9)
        #expect(abs(timing.starts[2]! - 200) < 1e-9)
    }

    @Test func keysFollowParagraphIndex() throws {
        let entry = AlignmentCatalog.Entry(paragraphCount: 2, duration: 200, starts: [0, 120])
        let timing = try #require(NarrationOriginalTiming.make(transcript: Self.transcript([100, 100], firstIndex: 10), alignment: entry))
        #expect(Set(timing.starts.keys) == [10, 11])
        #expect(abs(timing.duration(ofParagraph: 10)! - 120) < 1e-9)
        #expect(abs(timing.duration(ofParagraph: 11)! - 80) < 1e-9)
    }

    @Test func leadingSilenceIsOutsideTheFirstParagraph() throws {
        let entry = AlignmentCatalog.Entry(paragraphCount: 3, duration: 300, starts: [5, 100, 200])
        let timing = try #require(NarrationOriginalTiming.make(transcript: Self.transcript([100, 100, 100]), alignment: entry))
        #expect(timing.starts[0] == 5)
        #expect(abs(timing.duration(ofParagraph: 0)! - 95) < 1e-9)
    }

    @Test func mismatchedOrMissingAlignmentHasNoTiming() {
        let transcript = Self.transcript([100, 100, 100])
        #expect(NarrationOriginalTiming.make(transcript: transcript, alignment: nil) == nil)
        #expect(NarrationOriginalTiming.make(
            transcript: transcript, alignment: AlignmentCatalog.Entry(paragraphCount: 2, duration: 300, starts: [0, 100])) == nil)
        #expect(NarrationOriginalTiming.make(
            transcript: transcript, alignment: AlignmentCatalog.Entry(paragraphCount: 3, duration: 0, starts: [0, 1, 2])) == nil)
        #expect(NarrationOriginalTiming.make(
            transcript: Self.transcript([]), alignment: AlignmentCatalog.Entry(paragraphCount: 0, duration: 100, starts: [])) == nil)
        #expect(NarrationOriginalTiming.make(transcript: Self.transcript([100], id: "no-such-discourse")) == nil)
    }

    @Test func nonMonotonicStartsNeverGiveNegativeDurations() {
        let timing = NarrationOriginalTiming(starts: [0: 0, 1: 50, 2: 40], duration: 30)
        #expect(timing.duration(ofParagraph: 1) == 0)
        #expect(timing.duration(ofParagraph: 2) == 0)
        #expect(timing.duration(ofParagraph: 0) == 50)
    }

    @Test func shippedVigyanBhairavTantraEntryIsMonotonic() throws {
        let id = "english-Vigyan_Bhairav_Tantra_Vol_1-1"
        let lengths = (0..<109).map { 120 + ($0 * 37) % 400 }
        let timing = try #require(NarrationOriginalTiming.make(transcript: Self.transcript(lengths, id: id)))
        #expect(abs(timing.duration - 6158) < 2)
        #expect(timing.starts.count == 109)
        let ordered = (0..<109).map { timing.starts[$0]! }
        #expect(zip(ordered, ordered.dropFirst()).allSatisfy { $0 < $1 })
        #expect(ordered[0] > 0)
        #expect(ordered[108] < timing.duration)
        let spans = (0..<109).map { timing.duration(ofParagraph: $0)! }
        #expect(spans.allSatisfy { $0 > 0 })
        #expect(abs(ordered[0] + spans.reduce(0, +) - timing.duration) < 1e-6)
    }
}

struct NarrationPacingTargetsTests {

    private let timing = NarrationOriginalTiming(starts: [0: 0, 1: 100, 2: 200], duration: 300)

    @Test func splitsAParagraphAcrossItsChunksByCharacters() {
        let targets = NarrationPacingTargets.durations(
            chunks: [(0, 100), (1, 30), (1, 70), (2, 50)], timing: timing)
        #expect(targets.count == 4)
        let expected: [TimeInterval] = [100, 30, 70, 100]
        for (target, value) in zip(targets, expected) {
            #expect(abs(target! - value) < 1e-9)
        }
    }

    @Test func emptyChunksSplitEvenly() {
        let targets = NarrationPacingTargets.durations(chunks: [(1, 0), (1, 0)], timing: timing)
        #expect(targets == [50, 50])
    }

    @Test func noTimingGivesNilTargets() {
        #expect(NarrationPacingTargets.durations(chunks: [(0, 100), (1, 20)], timing: nil) == [nil, nil])
        #expect(NarrationPacingTargets.durations(chunks: [(0, 100), (9, 20)], timing: timing) == [100, nil])
        #expect(NarrationPacingTargets.durations(chunks: [], timing: timing).isEmpty)
    }
}

struct NarrationTimelineTests {

    /// Original paragraphs at 5 (after leading silence), 100 and 200 in a 300 s recording.
    private let timing = NarrationOriginalTiming(starts: [0: 5, 1: 100, 2: 200], duration: 300)

    private func segments(_ items: [(paragraph: Int, duration: TimeInterval)]) -> [NarrationSegment] {
        items.enumerated().map { i, item in
            NarrationSegment(index: i, sourceParagraphIndex: item.paragraph, text: "t", audioFileName: "\(i).m4a", duration: item.duration)
        }
    }

    /// Translated paragraphs: 0 → [0, 80) in two chunks, 1 → [80, 200), 2 → [200, 250).
    private var full: [NarrationSegment] { segments([(0, 40), (0, 40), (1, 120), (2, 50)]) }

    @Test func mapsParagraphStartsAndInteriorsLinearly() throws {
        let timeline = try #require(NarrationTimeline(segments: full, timing: timing))
        #expect(timeline.translatedTime(forOriginal: 5) == 0)
        #expect(abs(timeline.translatedTime(forOriginal: 100)! - 80) < 1e-9)
        #expect(abs(timeline.translatedTime(forOriginal: 150)! - 140) < 1e-9)
        #expect(abs(timeline.translatedTime(forOriginal: 200)! - 200) < 1e-9)
        #expect(abs(timeline.translatedTime(forOriginal: 300)! - 250) < 1e-9)
        #expect(abs(timeline.originalTime(forTranslated: 140)! - 150) < 1e-9)
        #expect(abs(timeline.originalTime(forTranslated: 250)! - 300) < 1e-9)
        #expect(timeline.originalTime(forTranslated: 251) == nil)
    }

    @Test func aNarrationStillPreparingMapsOnlyUpToItsLastParagraphStart() throws {
        // Paragraph 1 may have more chunks to come, so only paragraph 0 maps reliably.
        let partial = segments([(0, 40), (0, 40), (1, 30)])
        let timeline = try #require(NarrationTimeline(segments: partial, timing: timing, lastParagraphComplete: false))
        #expect(abs(timeline.translatedTime(forOriginal: 50)! - 40 * 45 / 95 * 2) < 1e-9)
        #expect(abs(timeline.translatedTime(forOriginal: 100)! - 80) < 1e-9)
        #expect(timeline.translatedTime(forOriginal: 120) == nil)
        #expect(timeline.originalTime(forTranslated: 95) == nil)
        #expect(NarrationTimeline(segments: segments([(0, 40)]), timing: timing, lastParagraphComplete: false) == nil)
    }

    @Test func roundTripsWithinTolerance() throws {
        let timeline = try #require(NarrationTimeline(segments: full, timing: timing))
        for original in stride(from: 5.0, through: 300.0, by: 0.7) {
            let translated = try #require(timeline.translatedTime(forOriginal: original))
            let back = try #require(timeline.originalTime(forTranslated: translated))
            #expect(abs(back - original) < 1e-6, "original \(original)")
        }
    }

    @Test func leadingSilenceClampsToTheStart() throws {
        let timeline = try #require(NarrationTimeline(segments: full, timing: timing))
        #expect(timeline.translatedTime(forOriginal: 0) == 0)
        #expect(timeline.translatedTime(forOriginal: 3) == 0)
        #expect(timeline.translatedTime(forOriginal: -10) == 0)
        #expect(timeline.originalTime(forTranslated: 0) == 5)
        #expect(timeline.originalTime(forTranslated: -1) == 5)
    }

    @Test func fullNarrationClampsPastTheRecordingEnd() throws {
        let timeline = try #require(NarrationTimeline(segments: full, timing: timing))
        #expect(timeline.translatedTime(forOriginal: 400) == 250)
        #expect(timeline.translatedTime(forOriginal: .nan) == nil)
        #expect(timeline.originalTime(forTranslated: .infinity) == nil)
    }

    @Test func partialPrefixStopsAtTheLastTranslatedParagraph() throws {
        let timeline = try #require(NarrationTimeline(segments: segments([(0, 40), (0, 40), (1, 120)]), timing: timing))
        #expect(abs(timeline.translatedTime(forOriginal: 150)! - 140) < 1e-9)
        #expect(timeline.translatedTime(forOriginal: 199.9) != nil)
        #expect(timeline.translatedTime(forOriginal: 200.1) == nil)
        #expect(timeline.translatedTime(forOriginal: 250) == nil)
        #expect(abs(timeline.originalTime(forTranslated: 200)! - 200) < 1e-9)
        #expect(timeline.originalTime(forTranslated: 200.1) == nil)
    }

    @Test func partialChunksOfTheLastParagraphStillMap() throws {
        let timeline = try #require(NarrationTimeline(segments: segments([(0, 40)]), timing: timing))
        #expect(abs(timeline.translatedTime(forOriginal: 52.5)! - 20) < 1e-9)
        #expect(timeline.translatedTime(forOriginal: 101) == nil)
    }

    @Test func mapsAreMonotonicOverManyPoints() throws {
        let timeline = try #require(NarrationTimeline(segments: full, timing: timing))
        var previous = -1.0
        for original in stride(from: -5.0, through: 320.0, by: 0.25) {
            let translated = try #require(timeline.translatedTime(forOriginal: original))
            #expect(translated >= previous)
            previous = translated
        }
        previous = -1
        for translated in stride(from: -5.0, through: 250.0, by: 0.25) {
            let original = try #require(timeline.originalTime(forTranslated: translated))
            #expect(original >= previous)
            previous = original
        }
    }

    @Test func degenerateInputsAreRejected() {
        #expect(NarrationTimeline(segments: [], timing: timing) == nil)
        #expect(NarrationTimeline(segments: segments([(0, 0), (1, 0)]), timing: timing) == nil)
        #expect(NarrationTimeline(segments: segments([(7, 30)]), timing: timing) == nil)
        let zeroSpan = NarrationOriginalTiming(starts: [0: 10, 1: 10], duration: 10)
        #expect(NarrationTimeline(segments: segments([(0, 30), (1, 30)]), timing: zeroSpan) == nil)
    }

    @Test func zeroLengthAndNonMonotonicDataStayMonotonic() throws {
        let tangled = NarrationOriginalTiming(starts: [0: 0, 1: 50, 2: 40, 3: 120], duration: 200)
        let timeline = try #require(NarrationTimeline(
            segments: segments([(0, 30), (1, 0), (2, 20), (3, -5), (3, .nan), (3, 40)]), timing: tangled))
        var previous = -1.0
        for original in stride(from: 0.0, through: 200.0, by: 0.5) {
            let translated = try #require(timeline.translatedTime(forOriginal: original))
            #expect(translated.isFinite && translated >= previous)
            previous = translated
        }
        #expect(abs(timeline.translatedTime(forOriginal: 200)! - 90) < 1e-9)
        #expect(abs(timeline.originalTime(forTranslated: 90)! - 200) < 1e-9)
    }

    @Test func untimedParagraphsFoldIntoTheirTimedNeighbour() throws {
        let sparse = NarrationOriginalTiming(starts: [0: 0, 2: 100], duration: 200)
        let timeline = try #require(NarrationTimeline(segments: segments([(0, 30), (1, 30), (2, 40)]), timing: sparse))
        #expect(abs(timeline.translatedTime(forOriginal: 100)! - 60) < 1e-9)
        #expect(abs(timeline.translatedTime(forOriginal: 50)! - 30) < 1e-9)
    }
}
