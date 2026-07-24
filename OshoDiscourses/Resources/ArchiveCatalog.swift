import Foundation

/// Maps catalog discourses to their mirrors on Archive.org.
///
/// oshoworld.com serves downloads at ~0.3 MB/s; the same files mirrored in the
/// archive.org item `osho-audio-discourses-collection` come down at ~4 MB/s
/// (measured ~12x faster). The mapping was generated offline by matching the
/// item's file inventory (via the archive.org metadata API) against the
/// catalog: 3,946 of 4,361 discourses (90%) across 238 of 259 series. Anything
/// unmapped — or any archive fetch that fails server-side — falls back to the
/// original oshoworld.com URL in DownloadService.
///
/// The item also carries per-track artwork PNGs (extracted embedded covers);
/// the first track's PNG doubles as a series cover for thumbnails.
///
/// URLs use the stable `archive.org/download/...` form, which redirects to a
/// healthy datanode — never hardcode `dnNNNN.xx.archive.org` hosts, they're
/// ephemeral.
enum ArchiveCatalog {

    struct SeriesEntry: Decodable {
        /// Path of the series folder inside the archive item, e.g.
        /// "OSHO_WORLD/Hindi/100-Maha Geeta 01-91 – Osho World".
        let folder: String
        /// Discourse number (as a string key) → filename inside the folder.
        /// Sparse: only numbers that verifiably exist on the archive.
        let files: [String: String]
        /// Cover artwork filename (first track's extracted PNG), if present.
        let cover: String?
    }

    static let itemBase = "https://archive.org/download/osho-audio-discourses-collection"

    /// Series id → archive entry, loaded once from the bundled JSON.
    private static let entries: [String: SeriesEntry] = {
        guard let url = Bundle.main.url(forResource: "ArchiveCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: SeriesEntry].self, from: data)
        else {
            print("[ArchiveCatalog] failed to load ArchiveCatalog.json — archive downloads disabled")
            return [:]
        }
        return decoded
    }()

    /// The series id embedded in a discourse id ("<seriesID>-<number>").
    /// Series ids themselves contain hyphens, so strip the numeric suffix by
    /// length rather than splitting.
    nonisolated static func seriesID(for discourse: CatalogDiscourse) -> String {
        String(discourse.id.dropLast(String(discourse.number).count + 1))
    }

    /// Archive.org download URL for a discourse, or nil if this discourse
    /// isn't (verifiably) mirrored there.
    static func audioURL(for discourse: CatalogDiscourse) -> URL? {
        guard let entry = entries[seriesID(for: discourse)],
              let file = entry.files[String(discourse.number)] else { return nil }
        return buildURL(path: "\(entry.folder)/\(file)")
    }

    /// Cover artwork URL for a series, or nil if none is mirrored.
    static func coverURL(forSeriesID seriesID: String) -> URL? {
        guard let entry = entries[seriesID], let cover = entry.cover else { return nil }
        return buildURL(path: "\(entry.folder)/\(cover)")
    }

    /// How many discourses of a series are mirrored (for tests/sanity).
    static func mappedCount(forSeriesID seriesID: String) -> Int {
        entries[seriesID]?.files.count ?? 0
    }

    static var mappedSeriesCount: Int { entries.count }
    static var mappedDiscourseCount: Int { entries.values.reduce(0) { $0 + $1.files.count } }

    private static func buildURL(path: String) -> URL? {
        // Folder names carry spaces, en-dashes, and '&'; percent-encode the
        // path portion (keeps '/'), matching how archive.org serves them.
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(string: "\(itemBase)/\(encoded)")
    }
}
