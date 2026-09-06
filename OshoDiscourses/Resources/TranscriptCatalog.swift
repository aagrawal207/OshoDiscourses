import Foundation

/// Maps catalog discourses to their transcript pages on oshoworld.com.
///
/// oshoworld.com renders each discourse page from a JSON API whose
/// `audio/get-description/{id}` call returns the full transcript as light HTML.
/// The mapping was generated offline by `scripts/build-transcript-catalog.py`,
/// which matched the app's mp3 paths against the site's audio inventory and
/// probed every page; only discourses whose page carries a real transcript are
/// listed, so availability can be shown without a network round trip.
///
/// The `_id` drives the API fetch; the page `slug` is kept as a fallback for
/// scraping the page's embedded Next.js data if the API ever changes shape.
enum TranscriptCatalog {

    struct Entry: Decodable, Equatable, Sendable {
        /// oshoworld audio document id, e.g. "66265929d26d4da463e8850d".
        let id: String
        /// Page slug, e.g. "ashtavakra-maha-geeta-01".
        let slug: String
        /// Word count measured at crawl time; a rough length hint only.
        let words: Int
    }

    static let apiBase = "https://oshoworld.com/api/server"
    static let siteBase = "https://oshoworld.com"

    /// Discourse id → entry, loaded once from the bundled JSON.
    private static let entries: [String: Entry] = {
        guard let url = Bundle.main.url(forResource: "TranscriptCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else {
            print("[TranscriptCatalog] failed to load TranscriptCatalog.json — transcripts disabled")
            return [:]
        }
        return decoded
    }()

    /// Series id → number of its discourses with a transcript. Discourse ids are
    /// "<seriesID>-<number>" and the number never contains a hyphen, so the
    /// series id is everything before the last one.
    private static let countsBySeries: [String: Int] = {
        var counts: [String: Int] = [:]
        for id in entries.keys {
            guard let cut = id.lastIndex(of: "-") else { continue }
            counts[String(id[..<cut]), default: 0] += 1
        }
        return counts
    }()

    static func entry(for discourseID: String) -> Entry? {
        entries[discourseID]
    }

    static func hasTranscript(_ discourseID: String) -> Bool {
        entries[discourseID] != nil
    }

    static func transcriptCount(forSeriesID seriesID: String) -> Int {
        countsBySeries[seriesID] ?? 0
    }

    static var mappedDiscourseCount: Int { entries.count }
    static var mappedSeriesCount: Int { countsBySeries.count }

    /// JSON endpoint returning `{"description": "<html>"}` (or `{"error": true}`).
    static func descriptionURL(for entry: Entry) -> URL? {
        URL(string: "\(apiBase)/audio/get-description/\(entry.id)")
    }

    /// The human-readable page; also the scrape fallback (see TranscriptFetcher).
    static func pageURL(for entry: Entry) -> URL? {
        URL(string: "\(siteBase)/\(entry.slug)")
    }
}
