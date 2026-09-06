import Foundation

/// One discourse's transcript, split into the paragraphs the reader scrolls.
struct Transcript: Codable, Equatable, Sendable {
    struct Paragraph: Codable, Equatable, Identifiable, Sendable {
        /// Position in the transcript; anchors and read positions refer to it.
        let index: Int
        let text: String
        /// Quoted material — the question being answered or the sutra being
        /// commented on — which the source marks up as a block.
        let isEmphasis: Bool
        var id: Int { index }
    }

    let discourseID: String
    /// oshoworld audio id the text was fetched under.
    let sourceID: String
    let fetchedAt: Date
    let paragraphs: [Paragraph]

    var wordCount: Int {
        paragraphs.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }
}

/// Turns the light HTML oshoworld serves as a discourse "description" into
/// paragraphs. The markup is a flat run of text with `<br>`/CRLF line breaks,
/// block emphasis via `<strong>`, `<q>` or the site's own `<cr>` tag, an
/// occasional inline `<i>`, and a trailing `<hr>`.
enum TranscriptParser {

    /// Tags that wrap a quoted block (question or sutra). Their text becomes
    /// emphasis paragraphs; consecutive lines inside one block stay together.
    private static let emphasisTags: Set<String> = ["strong", "b", "q", "cr", "blockquote"]
    /// Tags that end a line. Everything else is stripped, keeping its text.
    private static let breakTags: Set<String> = ["br", "hr", "p", "div", "li", "tr", "h1", "h2", "h3", "h4"]

    private static let emphasisOpen: Character = "\u{01}"
    private static let emphasisClose: Character = "\u{02}"

    static func paragraphs(fromHTML html: String) -> [Transcript.Paragraph] {
        let marked = decodeEntities(replaceTags(in: html))

        var result: [Transcript.Paragraph] = []
        var pendingEmphasis: [String] = []
        var current = ""
        var emphasized = 0
        var plain = 0
        var inEmphasis = false
        // Consecutive line breaks since the last text or tag boundary. Two in a
        // row is a blank line, which separates one quoted block from the next.
        var blankRun = 0

        func flushEmphasis() {
            guard !pendingEmphasis.isEmpty else { return }
            result.append(.init(index: result.count, text: pendingEmphasis.joined(separator: "\n"), isEmphasis: true))
            pendingEmphasis.removeAll()
        }

        func endSegment() {
            defer { current = ""; emphasized = 0; plain = 0 }
            let text = current.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if emphasized > 0 && emphasized >= plain {
                pendingEmphasis.append(text)
            } else {
                flushEmphasis()
                result.append(.init(index: result.count, text: text, isEmphasis: false))
            }
        }

        for ch in marked {
            switch ch {
            case "\n":
                if plain + emphasized > 0 {
                    endSegment()
                    blankRun = 1
                } else {
                    blankRun += 1
                    if blankRun >= 2 { flushEmphasis() }
                }
            case emphasisOpen, emphasisClose:
                // A block boundary inside a line ("भगवान,<cr>question…") starts
                // a new paragraph; the site never uses these tags inline.
                if plain + emphasized > 0 { endSegment() }
                inEmphasis = ch == emphasisOpen
                blankRun = 0
            default:
                current.append(ch)
                guard !ch.isWhitespace else { continue }
                if inEmphasis { emphasized += 1 } else { plain += 1 }
            }
        }
        endSegment()
        flushEmphasis()
        return result
    }

    /// Replace tags with line breaks or emphasis sentinels, drop the rest.
    private static func replaceTags(in html: String) -> String {
        var out = ""
        out.reserveCapacity(html.count)
        var index = html.startIndex
        while index < html.endIndex {
            let ch = html[index]
            if ch == "<", let close = html[index...].firstIndex(of: ">") {
                let inner = html[html.index(after: index)..<close]
                let isClosing = inner.hasPrefix("/")
                let nameStart = isClosing ? inner.index(after: inner.startIndex) : inner.startIndex
                let name = inner[nameStart...]
                    .prefix { $0.isLetter || $0.isNumber }
                    .lowercased()
                if emphasisTags.contains(name) {
                    out.append(isClosing ? emphasisClose : emphasisOpen)
                } else if breakTags.contains(name) {
                    out.append("\n")
                }
                index = html.index(after: close)
            } else if ch == "\r\n" || ch == "\r" {
                // CRLF is a single Character in Swift, so both spellings of a
                // line break are normalised here.
                out.append("\n")
                index = html.index(after: index)
            } else {
                out.append(ch)
                index = html.index(after: index)
            }
        }
        return out
    }

    /// The source is raw UTF-8 (curly quotes and Devanagari appear literally),
    /// so only the structural entities and numeric references need decoding.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
            "hellip": "\u{2026}", "mdash": "\u{2014}", "ndash": "\u{2013}",
            "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        ]
        var out = ""
        out.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            guard ch == "&",
                  let semi = text[index...].prefix(12).firstIndex(of: ";") else {
                out.append(ch)
                index = text.index(after: index)
                continue
            }
            let body = text[text.index(after: index)..<semi]
            var replacement: String?
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                if let v = UInt32(body.dropFirst(2), radix: 16), let s = Unicode.Scalar(v) { replacement = String(Character(s)) }
            } else if body.hasPrefix("#") {
                if let v = UInt32(body.dropFirst()), let s = Unicode.Scalar(v) { replacement = String(Character(s)) }
            } else {
                replacement = named[String(body)]
            }
            if let replacement {
                out.append(replacement)
                index = text.index(after: semi)
            } else {
                out.append(ch)
                index = text.index(after: index)
            }
        }
        return out
    }
}
