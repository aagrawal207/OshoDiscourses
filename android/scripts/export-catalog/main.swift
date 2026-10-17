// Compiled together with the iOS catalog sources by ../export-catalog.sh; see its header.
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write("usage: export-catalog <catalog.json> <golden dir>\n".data(using: .utf8)!)
    exit(2)
}
let catalogOut = URL(fileURLWithPath: arguments[1])
let goldenDir = URL(fileURLWithPath: arguments[2], isDirectory: true)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("export-catalog: \(message)\n".data(using: .utf8)!)
    exit(1)
}

// The resource loaders print and fall back to empty when Bundle.main misses the JSON;
// an empty override set would silently bake pattern URLs into the golden file.
guard OshoworldCatalog.overrideCount > 0 else { fail("OshoworldCatalog.json did not load") }
guard ArchiveCatalog.mappedSeriesCount > 0 else { fail("ArchiveCatalog.json did not load") }
guard TranscriptCatalog.mappedDiscourseCount > 0 else { fail("TranscriptCatalog.json did not load") }

func optional(_ value: String?) -> Any { value.map { $0 as Any } ?? NSNull() }

let series: [[String: Any]] = Catalog.allSeries.map { s in
    [
        "name": s.name,
        "filePrefix": s.filePrefix,
        "count": s.count,
        "language": s.language.rawValue,
        "urlType": s.urlType.rawValue,
        "slug": optional(s.slug),
        "fileTitle": optional(s.fileTitle),
        "folderName": optional(s.folderName),
    ]
}

// SeriesMetadata keeps its table private, so it is read through the public lookup
// for every name the app can ask about.
let curatedNames = Catalog.popularEnglishNames + Catalog.beginnerEnglishNames
    + Catalog.popularHindiNames + Catalog.beginnerHindiNames
var descriptions: [String: Any] = [:]
var themeLabels: [String: String] = [:]
for name in Catalog.allSeries.map(\.name) + curatedNames {
    guard let d = SeriesMetadata.description(for: name) else { continue }
    descriptions[name] = [
        "sourceText": d.sourceText,
        "year": optional(d.year),
        "location": optional(d.location),
        "themes": d.themes,
    ] as [String: Any]
    // LibraryView labels theme chips with Foundation's `capitalized`; Kotlin reimplements it.
    for theme in d.themes { themeLabels[theme.lowercased()] = theme.lowercased().capitalized }
}

let catalog: [String: Any] = [
    "series": series,
    "curated": [
        "popularEnglish": Catalog.popularEnglishNames,
        "beginnerEnglish": Catalog.beginnerEnglishNames,
        "popularHindi": Catalog.popularHindiNames,
        "beginnerHindi": Catalog.beginnerHindiNames,
    ],
    "descriptions": descriptions,
]

do {
    let data = try JSONSerialization.data(
        withJSONObject: catalog,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    try FileManager.default.createDirectory(
        at: catalogOut.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try (data + "\n".data(using: .utf8)!).write(to: catalogOut)
} catch {
    fail("writing \(catalogOut.path): \(error)")
}

func cell(_ value: String?) -> String {
    guard let value else { return "-" }
    precondition(!value.contains("\t") && !value.contains("\n"), "unexpected separator in \(value)")
    return value.isEmpty ? "-" : value
}

// The request URL DownloadService builds from the un-encoded oshoworld path.
func encodedOshoworld(_ raw: String) -> String? {
    guard !raw.isEmpty else { return nil }
    return URL(string: raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw)?.absoluteString
}

var discourseLines = ["id\tnumber\tpatternURL\taudioURL\tencodedAudioURL\tarchiveURL"]
for s in Catalog.allSeries {
    for d in Catalog.discourses(for: s) {
        discourseLines.append([
            d.id,
            String(d.number),
            cell(patternAudioURL(series: s, discourseNumber: d.number)),
            cell(d.audioURL),
            cell(encodedOshoworld(d.audioURL)),
            cell(ArchiveCatalog.audioURL(for: d)?.absoluteString),
        ].joined(separator: "\t"))
    }
}

var seriesLines = ["id\tlanguage\tcount\ttranscripts\tcoverURL\tsubtitle3\tsearchText"]
for s in Catalog.allSeries {
    seriesLines.append([
        s.id,
        s.language.rawValue,
        String(s.count),
        String(TranscriptCatalog.transcriptCount(forSeriesID: s.id)),
        cell(ArchiveCatalog.coverURL(forSeriesID: s.id)?.absoluteString),
        cell(SeriesMetadata.discourseSubtitle(number: 3, seriesName: s.name)),
        cell(SeriesMetadata.searchCorpus[s.name]),
    ].joined(separator: "\t"))
}

do {
    try FileManager.default.createDirectory(at: goldenDir, withIntermediateDirectories: true)
    try (discourseLines.joined(separator: "\n") + "\n")
        .write(to: goldenDir.appendingPathComponent("discourses.tsv"), atomically: true, encoding: .utf8)
    try (seriesLines.joined(separator: "\n") + "\n")
        .write(to: goldenDir.appendingPathComponent("series.tsv"), atomically: true, encoding: .utf8)
    let themeLines = ["theme\tlabel"] + themeLabels.keys.sorted().map { "\($0)\t\(themeLabels[$0]!)" }
    try (themeLines.joined(separator: "\n") + "\n")
        .write(to: goldenDir.appendingPathComponent("themes.tsv"), atomically: true, encoding: .utf8)
} catch {
    fail("writing golden files: \(error)")
}

let total = Catalog.allSeries.reduce(0) { $0 + $1.count }
print("export-catalog: \(Catalog.allSeries.count) series, \(total) discourses, \(descriptions.count) descriptions")
