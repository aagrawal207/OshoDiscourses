import Testing
@testable import OshoDiscourses

@Suite
struct OshoDiscoursesTests {

    @Test func catalogHasSeries() {
        // 351 series / 5,481 discourses after the 2026-09 oshoworld crawl.
        #expect(Catalog.allSeries.count >= 350)
    }

    @Test func catalogHasDiscourses() {
        let total = Catalog.allSeries.reduce(0) { $0 + $1.count }
        #expect(total >= 5400)
    }

    @Test func urlBuildingUnderscore() {
        guard let series = Catalog.allSeries.first(where: { $0.name == "Beyond Enlightenment" }) else {
            Issue.record("Missing series")
            return
        }
        let url = buildAudioURL(series: series, discourseNumber: 1)
        #expect(url.contains("Beyond_Enlightenment"))
        #expect(url.hasSuffix("01.mp3"))
    }

    @Test func urlBuildingSlug() {
        guard let series = Catalog.allSeries.first(where: { $0.name == "The Book of Wisdom" }) else {
            Issue.record("Missing series")
            return
        }
        let url = buildAudioURL(series: series, discourseNumber: 5)
        #expect(url.contains("the-book-of-wisdom"))
        #expect(url.hasSuffix("05.mp3"))
    }

    @Test func urlBuildingOshoPrefix() {
        guard let series = Catalog.allSeries.first(where: { $0.name == "Ashtavakra Maha Geeta" }) else {
            Issue.record("Missing series")
            return
        }
        let url = buildAudioURL(series: series, discourseNumber: 10)
        #expect(url.contains("OSHO-Maha_Geeta"))
        #expect(url.contains("Hindi Audio"))
    }

    @Test func curatedListsExist() {
        #expect(!Catalog.popularEnglish.isEmpty)
        #expect(!Catalog.beginnerEnglish.isEmpty)
        #expect(!Catalog.popularHindi.isEmpty)
        #expect(!Catalog.beginnerHindi.isEmpty)
    }

    @Test func curatedListsResolveEveryName() {
        // compactMap silently drops a typo'd name — a misspelling would just
        // shrink the Home section with no other signal. Pin exact counts.
        #expect(Catalog.popularEnglish.count == Catalog.popularEnglishNames.count)
        #expect(Catalog.beginnerEnglish.count == Catalog.beginnerEnglishNames.count)
        #expect(Catalog.popularHindi.count == Catalog.popularHindiNames.count)
        #expect(Catalog.beginnerHindi.count == Catalog.beginnerHindiNames.count)
    }

    @Test func cachedDiscoursesMatchSeriesCounts() {
        // The per-series cache must cover every series with the exact count and
        // ids the URL builder used to produce on the fly.
        for series in Catalog.allSeries {
            let discourses = Catalog.discourses(for: series)
            #expect(discourses.count == series.count)
            #expect(discourses.first?.id == "\(series.id)-1")
        }
    }
}

/// The crawled oshoworld path overrides (OshoworldCatalog.json) and the
/// `.catalog` URL type they make possible.
@Suite
struct OshoworldCatalogTests {

    @Test func overridesLoad() {
        // 923 at generation time; a floor so regenerating doesn't break it.
        #expect(OshoworldCatalog.overrideCount >= 800)
    }

    @Test func renamedFolderUsesTheSitePathNotThePattern() throws {
        // oshoworld renamed these to "... Vol 1 01.mp3"; the pattern alone 404s.
        let series = try #require(Catalog.allSeries.first { $0.name == "The Perfect Master" })
        #expect(patternAudioURL(series: series, discourseNumber: 1).hasSuffix("The Perfect Master 01.mp3"))
        #expect(buildAudioURL(series: series, discourseNumber: 1).hasSuffix("the-perfect-master-series/The Perfect Master Vol 1 01.mp3"))
        #expect(buildAudioURL(series: series, discourseNumber: 11).hasSuffix("The Perfect Master Vol 2 01.mp3"))
    }

    @Test func catalogTypeSeriesResolveEveryDiscourse() {
        // No pattern fits these, so every discourse must have an override —
        // otherwise the URL is empty and the download can never start.
        for series in Catalog.allSeries where series.urlType == .catalog {
            #expect(patternAudioURL(series: series, discourseNumber: 1).isEmpty)
            for discourse in Catalog.discourses(for: series) {
                // Most live under /wp-content/uploads/, one stray file under
                // /uploads/music/; both are the site's own paths.
                #expect(discourse.audioURL.hasPrefix("https://www.oshoworld.com/"), "\(discourse.id)")
                #expect(discourse.audioURL.hasSuffix(".mp3"), "\(discourse.id)")
            }
        }
    }

    @Test func skippedSiteNumbersFollowThePosition() throws {
        // The site skips 18 in this series; the app's #18 is the site's 19th file.
        let series = try #require(Catalog.allSeries.first { $0.name == "Swarn Pakhi Tha Jo Kabhi" })
        #expect(series.count == 22)
        #expect(buildAudioURL(series: series, discourseNumber: 18).hasSuffix("OSHO-Swarn_Pakhi_Tha_Jo_Kabhi_19.mp3"))
        #expect(buildAudioURL(series: series, discourseNumber: 17).hasSuffix("OSHO-Swarn_Pakhi_Tha_Jo_Kabhi_17.mp3"))
    }

    @Test func noDiscourseIsLeftWithoutAnyURL() {
        for series in Catalog.allSeries {
            for discourse in Catalog.discourses(for: series) {
                #expect(!discourse.audioURL.isEmpty, "\(discourse.id)")
            }
        }
    }

    @Test func seriesIDsAreUnique() {
        let ids = Catalog.allSeries.map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}
