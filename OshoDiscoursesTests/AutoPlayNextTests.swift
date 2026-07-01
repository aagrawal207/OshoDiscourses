import Testing
@testable import OshoDiscourses

/// The download-only advance rule behind Auto-Play Next: given the ordered
/// discourses of a series and which are on disk, find the next *downloaded* one
/// after the current. It must skip gaps (not-yet-downloaded talks), never go
/// backwards, and stop at the end of the series.
struct AutoPlayNextTests {
    private let series = ["s-1", "s-2", "s-3", "s-4"]

    @Test func advancesToImmediateNextWhenDownloaded() {
        let next = AudioPlayerService.nextDownloadedId(
            after: "s-1", in: series, isDownloaded: { _ in true }
        )
        #expect(next == "s-2")
    }

    @Test func skipsGapToNextDownloaded() {
        // s-2 not on disk (Smart Delete, or never fetched); jump to s-3.
        let downloaded: Set<String> = ["s-1", "s-3", "s-4"]
        let next = AudioPlayerService.nextDownloadedId(
            after: "s-1", in: series, isDownloaded: { downloaded.contains($0) }
        )
        #expect(next == "s-3")
    }

    @Test func returnsNilWhenNothingDownloadedAhead() {
        let downloaded: Set<String> = ["s-1"]
        let next = AudioPlayerService.nextDownloadedId(
            after: "s-1", in: series, isDownloaded: { downloaded.contains($0) }
        )
        #expect(next == nil)
    }

    @Test func returnsNilAtEndOfSeries() {
        let next = AudioPlayerService.nextDownloadedId(
            after: "s-4", in: series, isDownloaded: { _ in true }
        )
        #expect(next == nil)
    }

    @Test func neverAdvancesBackwards() {
        // Only an earlier talk is downloaded — must not return it.
        let downloaded: Set<String> = ["s-1"]
        let next = AudioPlayerService.nextDownloadedId(
            after: "s-3", in: series, isDownloaded: { downloaded.contains($0) }
        )
        #expect(next == nil)
    }

    @Test func returnsNilForUnknownCurrent() {
        let next = AudioPlayerService.nextDownloadedId(
            after: "not-in-series", in: series, isDownloaded: { _ in true }
        )
        #expect(next == nil)
    }
}
