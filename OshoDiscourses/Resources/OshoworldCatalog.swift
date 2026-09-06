import Foundation

/// oshoworld.com mp3 paths for discourses whose file the naming patterns in
/// `patternAudioURL` get wrong.
///
/// The site has renamed files inside many upload folders since the patterns
/// were written ("The Perfect Master 01.mp3" became "The Perfect Master Vol 1
/// 01.mp3"), and some series skip numbers or mix several volumes in one
/// folder. `scripts/build-transcript-catalog.py --audio-out` compares every
/// pattern URL with the path the site's own API reports and writes only the
/// differences here, so the file stays small and a series that follows its
/// pattern costs nothing.
///
/// Paths are stored un-encoded (literal spaces), like the pattern URLs;
/// `DownloadService` percent-encodes at request time.
enum OshoworldCatalog {

    /// Discourse id → path under the site root, e.g.
    /// "/wp-content/uploads/2020/11/Hindi Audio/OSHO-Swarn_Pakhi_Tha_Jo_Kabhi_19.mp3".
    private static let overrides: [String: String] = {
        guard let url = Bundle.main.url(forResource: "OshoworldCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            print("[OshoworldCatalog] failed to load OshoworldCatalog.json — pattern URLs only")
            return [:]
        }
        return decoded
    }()

    static func path(forSeriesID seriesID: String, number: Int) -> String? {
        overrides["\(seriesID)-\(number)"]
    }

    static var overrideCount: Int { overrides.count }
}
