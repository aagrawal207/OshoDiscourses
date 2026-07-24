import Testing
import Foundation
@testable import OshoDiscourses

/// The Archive.org mirror mapping (bundled ArchiveCatalog.json) and the
/// source-fallback rule. The mapping was generated offline against the
/// archive item's file inventory; these tests pin that it ships, loads, and
/// resolves the known-good example (Ashtavakra Maha Geeta #1) to the URL
/// verified by hand — and that unmapped discourses cleanly return nil so the
/// oshoworld fallback takes over.
@MainActor
struct ArchiveCatalogTests {

    @Test func mappingLoadsAndCoversMostOfTheCatalog() {
        // 3,946 of 4,361 mapped at generation time. Assert a floor, not the
        // exact number, so regenerating the mapping doesn't break the test.
        #expect(ArchiveCatalog.mappedSeriesCount >= 230)
        #expect(ArchiveCatalog.mappedDiscourseCount >= 3900)
    }

    @Test func ashtavakraMahaGeetaResolvesToKnownURL() throws {
        let series = try #require(Catalog.allSeries.first { $0.name == "Ashtavakra Maha Geeta" })
        let discourse = try #require(Catalog.discourses(for: series).first)
        let url = try #require(ArchiveCatalog.audioURL(for: discourse))
        #expect(url.absoluteString ==
            "https://archive.org/download/osho-audio-discourses-collection/OSHO_WORLD/Hindi/100-Maha%20Geeta%2001-91%20%E2%80%93%20Osho%20World/OSHO-Maha_Geeta_01.mp3")
    }

    @Test func everyMappedURLIsWellFormed() {
        // Percent-encoding must produce a valid https URL for every mapped
        // discourse (folder names carry spaces, en-dashes, '&', Devanagari).
        for series in Catalog.allSeries {
            for discourse in Catalog.discourses(for: series) {
                if let url = ArchiveCatalog.audioURL(for: discourse) {
                    #expect(url.scheme == "https")
                    #expect(url.host() == "archive.org")
                }
            }
        }
    }

    @Test func seriesIDRoundTripsForEveryDiscourse() {
        // seriesID(for:) strips the "-<number>" suffix by length; series ids
        // themselves contain hyphens and digits, so pin the round trip.
        for series in Catalog.allSeries {
            for discourse in Catalog.discourses(for: series) {
                #expect(ArchiveCatalog.seriesID(for: discourse) == series.id)
            }
        }
    }

    @Test func unmappedDiscourseReturnsNil() throws {
        // "A Sudden Clash of Thunder" is absent from the archive item.
        let series = try #require(Catalog.allSeries.first { $0.name == "A Sudden Clash of Thunder" })
        let discourse = try #require(Catalog.discourses(for: series).first)
        #expect(ArchiveCatalog.audioURL(for: discourse) == nil)
        #expect(ArchiveCatalog.coverURL(forSeriesID: series.id) == nil)
    }

    @Test func mappedSeriesHasCover() throws {
        let series = try #require(Catalog.allSeries.first { $0.name == "Ashtavakra Maha Geeta" })
        let cover = try #require(ArchiveCatalog.coverURL(forSeriesID: series.id))
        #expect(cover.absoluteString.hasSuffix(".png"))
    }

    // MARK: - Fallback decision

    @Test func serverSideFailuresFallBackToNextSource() {
        #expect(DownloadService.shouldTryNextSource(after: DownloadService.DownloadError.notFound))
        #expect(DownloadService.shouldTryNextSource(after: DownloadService.DownloadError.serverError(503)))
        #expect(DownloadService.shouldTryNextSource(after: DownloadService.DownloadError.notAudio))
        #expect(DownloadService.shouldTryNextSource(after: URLError(.timedOut)))
    }

    @Test func deviceLocalFailuresDoNotFallBack() {
        // Retrying another host can't fix these — and for the cellular gate it
        // would wrongly restart the transfer the user meant to gate.
        #expect(!DownloadService.shouldTryNextSource(after: DownloadService.DownloadError.offline))
        #expect(!DownloadService.shouldTryNextSource(after: DownloadService.DownloadError.wifiOnly))
        #expect(!DownloadService.shouldTryNextSource(after: DownloadService.DownloadError.diskFull))
        #expect(!DownloadService.shouldTryNextSource(after: CancellationError()))
    }
}
