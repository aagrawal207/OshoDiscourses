import Testing
@testable import OshoDiscourses

@Suite
struct OshoDiscoursesTests {

    @Test func catalogHasSeries() {
        #expect(Catalog.allSeries.count > 200)
    }

    @Test func catalogHasDiscourses() {
        let total = Catalog.allSeries.reduce(0) { $0 + $1.count }
        #expect(total > 4000)
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
