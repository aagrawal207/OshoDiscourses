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
}
