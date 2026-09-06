import Testing
@testable import OshoDiscourses

@Suite
struct SeriesMetadataTests {

    @Test func popularSeriesHaveDescriptions() {
        for name in Catalog.popularEnglishNames {
            let desc = SeriesMetadata.description(for: name)
            #expect(desc != nil, "Missing metadata for: \(name)")
        }
    }

    @Test func beginnerSeriesHaveDescriptions() {
        for name in Catalog.beginnerEnglishNames {
            let desc = SeriesMetadata.description(for: name)
            #expect(desc != nil, "Missing metadata for: \(name)")
        }
    }

    @Test func popularHindiHaveDescriptions() {
        for name in Catalog.popularHindiNames {
            let desc = SeriesMetadata.description(for: name)
            #expect(desc != nil, "Missing metadata for: \(name)")
        }
    }

    @Test func searchableTextIncludesThemes() {
        let text = SeriesMetadata.searchableText(for: "The Mustard Seed")
        #expect(text.contains("Jesus"))
        #expect(text.contains("Gospel"))
    }

    @Test func unknownSeriesReturnsNil() {
        let desc = SeriesMetadata.description(for: "Nonexistent Series XYZ")
        #expect(desc == nil)
    }

    @Test func searchableTextForUnknownReturnsSeries() {
        let text = SeriesMetadata.searchableText(for: "Unknown Series")
        #expect(text == "Unknown Series")
    }

    // MARK: - Player subtitle

    @Test func discourseSubtitleIncludesPlaceAndYear() {
        let subtitle = SeriesMetadata.discourseSubtitle(
            number: 1,
            seriesName: "Ashtavakra Maha Geeta"
        )
        #expect(subtitle == "Discourse 1 · Pune, 1976")
    }

    /// Most of the catalog has no metadata, so the subtitle has to degrade to
    /// just the number with no trailing separator.
    @Test func discourseSubtitleWithoutMetadataIsJustTheNumber() {
        let subtitle = SeriesMetadata.discourseSubtitle(
            number: 12,
            seriesName: "Nonexistent Series XYZ"
        )
        #expect(subtitle == "Discourse 12")
    }

    /// Every series that does have metadata must produce a clean subtitle: no
    /// dangling separator, no half pair, and never an empty origin.
    @Test func discourseSubtitleIsWellFormedForEverySeries() {
        for series in Catalog.allSeries {
            let subtitle = SeriesMetadata.discourseSubtitle(number: 3, seriesName: series.name)
            #expect(subtitle.hasPrefix("Discourse 3"), "Bad prefix for \(series.name): \(subtitle)")
            #expect(!subtitle.hasSuffix("·"), "Dangling separator for \(series.name)")
            #expect(!subtitle.hasSuffix(","), "Dangling comma for \(series.name)")
            #expect(!subtitle.contains("· ,"), "Empty location for \(series.name)")
            #expect(!subtitle.contains(", ·"), "Empty year for \(series.name)")
        }
    }
}
