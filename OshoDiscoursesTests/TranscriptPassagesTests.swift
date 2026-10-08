import Testing
import Foundation
@testable import OshoDiscourses

struct TranscriptPassagesTests {

    private let first = "The first sentence is long enough to stand on its own here."
    private let second = "The second sentence is also long enough to stand alone today."
    private let third = "A third line follows a line break and is long enough to stand."
    private let next = "Another paragraph begins here with enough letters to count fully."

    private var blocks: [TranscriptView.Block] {
        let transcript = Transcript(discourseID: "x", sourceID: "y", fetchedAt: Date(), paragraphs: [
            .init(index: 0, text: "\(first) \(second)\n\(third)", isEmphasis: false),
            .init(index: 1, text: next, isEmphasis: false),
        ])
        return TranscriptView.blocks(for: transcript, sentences: true)
    }

    @Test func sentenceRowsOfOneParagraphRejoinWithTheirOriginalSpacing() {
        let rows = blocks
        #expect(rows.map(\.text) == [first, second, third, next])
        #expect(TranscriptPassages.text(for: Array(rows.prefix(3))) == "\(first) \(second)\n\(third)")
    }

    @Test func passagesFollowReadingOrderWhateverOrderTheyWerePicked() {
        let rows = blocks
        #expect(TranscriptPassages.text(for: [rows[3], rows[1]]) == "\(second)\n\n\(next)")
    }

    @Test func aSkippedRowStartsANewParagraph() {
        let rows = blocks
        #expect(TranscriptPassages.text(for: [rows[0], rows[2]]) == "\(first)\n\n\(third)")
    }

    @Test func blockLayoutKeepsAShortParagraphAsOneRow() {
        let transcript = Transcript(discourseID: "x", sourceID: "y", fetchedAt: Date(), paragraphs: [
            .init(index: 0, text: "\(first) \(second)", isEmphasis: false),
        ])
        let rows = TranscriptView.blocks(for: transcript, sentences: false)
        #expect(rows.count == 1)
        #expect(TranscriptPassages.text(for: rows) == "\(first) \(second)")
    }

    @Test func selectUpToHereFillsFromTheNearestPickedRow() {
        let rows = blocks
        let extended = TranscriptPassages.extending([rows[0].id], to: rows[3], in: rows)
        #expect(extended == Set(rows.map(\.id)))

        // Rows 0 and 3 picked: extending to 2 fills from 3, leaving 1 alone.
        let fromNearest = TranscriptPassages.extending([rows[0].id, rows[3].id], to: rows[2], in: rows)
        #expect(fromNearest == [rows[0].id, rows[2].id, rows[3].id])
    }

    @Test func selectUpToHereWithNothingPickedSelectsOnlyThatRow() {
        let rows = blocks
        #expect(TranscriptPassages.extending([], to: rows[1], in: rows) == [rows[1].id])
    }

    @Test func sharedTextCarriesTheDiscourse() {
        #expect(TranscriptPassages.shareText("Be.", series: "A Bird on the Wing", number: 3) == "Be.\n\n— Osho, A Bird on the Wing #3")
        #expect(TranscriptPassages.shareText("Be.", series: nil, number: nil) == "Be.")
    }
}
