import Foundation
import AVFoundation
import Speech

/// Builds `AlignmentCatalog.json`: for every discourse with a transcript,
/// download the audio, run Apple's on-device recogniser, align the words to
/// the paragraphs with the app's own `TranscriptAligner`, and keep the
/// paragraph start times. Runs on macOS 26 (same Speech framework as iOS 26).
///
///   align [--language english|hindi] [--series <seriesID>] [--limit N]
///         [--parallel N] [--retry-failed | --retry-downloads] [--only <discourseID>]
///   merge      write Resources/AlignmentCatalog.json from the results so far
///   report     print coverage and failure counts
///
/// One JSON per discourse lands in build/alignments/, so the run resumes where
/// it stopped and a failure never costs more than one discourse.
@main
struct AlignTranscripts {

    static let repoRoot: URL = {
        // build/AlignTranscripts/AlignTranscripts -> repo root
        URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }()
    static let resultsDir = repoRoot.appendingPathComponent("build/alignments")
    static let crawlDir = repoRoot.appendingPathComponent("build/transcript-crawl")
    static let catalogURL = repoRoot.appendingPathComponent("OshoDiscourses/Resources/AlignmentCatalog.json")

    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        let command = args.isEmpty ? "align" : args.removeFirst()
        let options = Options(args)
        do {
            switch command {
            case "align": try await align(options)
            case "merge": try merge()
            case "report": try report()
            default:
                print("unknown command \(command)")
                exit(2)
            }
        } catch {
            print("fatal: \(error)")
            exit(1)
        }
    }

    // MARK: - Options

    struct Options {
        var language: SeriesInfo.Language?
        var series: String?
        var only: String?
        var limit = Int.max
        var parallel = 1
        var retryFailed = false
        var retryDownloads = false

        init(_ args: [String]) {
            var i = 0
            func value() -> String { i += 1; return i < args.count ? args[i] : "" }
            while i < args.count {
                switch args[i] {
                case "--language": language = value() == "hindi" ? .hindi : .english
                case "--series": series = value()
                case "--only": only = value()
                case "--limit": limit = Int(value()) ?? Int.max
                case "--parallel": parallel = max(1, Int(value()) ?? 1)
                case "--retry-failed": retryFailed = true
                case "--retry-downloads": retryDownloads = true
                default: print("ignoring argument \(args[i])")
                }
                i += 1
            }
        }
    }

    // MARK: - Work list

    /// Curated series first so a partial run already covers what people play
    /// most, then everything else in catalog order.
    static func workList(_ options: Options) -> [(CatalogDiscourse, SeriesInfo)] {
        let curated = Catalog.popularEnglish + Catalog.beginnerEnglish + Catalog.popularHindi + Catalog.beginnerHindi
        var seen: Set<String> = []
        var ordered: [SeriesInfo] = []
        for s in curated + Catalog.allSeries where seen.insert(s.id).inserted { ordered.append(s) }
        var items: [(CatalogDiscourse, SeriesInfo)] = []
        for series in ordered {
            if let language = options.language, series.language != language { continue }
            if let wanted = options.series, series.id != wanted { continue }
            for d in Catalog.discourses(for: series) where TranscriptCatalog.hasTranscript(d.id) {
                if let only = options.only, d.id != only { continue }
                items.append((d, series))
            }
        }
        return items
    }

    // MARK: - Align

    struct Result: Codable {
        let id: String
        var paragraphCount: Int?
        var duration: TimeInterval?
        var starts: [TimeInterval?]?
        var engine: String?
        var words: Int?
        var source: String?
        var seconds: Int?
        var error: String?
        let createdAt: Date

        var isFailure: Bool { error != nil }
    }

    static func resultURL(_ id: String) -> URL { resultsDir.appendingPathComponent("\(id).json") }

    static func loadResult(_ id: String) -> Result? {
        guard let data = try? Data(contentsOf: resultURL(id)) else { return nil }
        return try? decoder.decode(Result.self, from: data)
    }

    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }()

    static func align(_ options: Options) async throws {
        try FileManager.default.createDirectory(at: resultsDir, withIntermediateDirectories: true)
        let all = workList(options)
        let pending = all.filter { item in
            guard let existing = loadResult(item.0.id) else { return true }
            return existing.isFailure && (options.retryFailed ||
                (options.retryDownloads && existing.error?.hasPrefix("audio unavailable:") == true))
        }.prefix(options.limit)
        print("\(all.count) discourses with transcripts, \(pending.count) to align, parallel=\(options.parallel)")
        guard !pending.isEmpty else { return }

        // One reservation per language up front; the inventory allows only a
        // few reserved locales and the reservation must precede any asset call.
        var engines: [SeriesInfo.Language: SpeechWordRecognizer.Engine] = [:]
        for language in Set(pending.map(\.1.language)) {
            guard let engine = await SpeechWordRecognizer.preferredEngine(for: language) else {
                print("no speech engine for \(language); skipping that language")
                continue
            }
            engines[language] = engine
            print("\(language): \(engine.name)")
        }

        let queue = WorkQueue(Array(pending))
        let started = Date()
        let total = pending.count
        let enginesByLanguage = engines
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<options.parallel {
                group.addTask { [enginesByLanguage] in
                    let engines = enginesByLanguage
                    while let (index, item) = await queue.next() {
                        guard let engine = engines[item.1.language] else { continue }
                        var result = await alignOne(item.0, series: item.1, engine: engine)
                        // A dead connection fails every download instantly and
                        // would burn through the whole list; wait it out instead.
                        while result.error?.contains("offline") == true || result.error?.contains("connection was lost") == true {
                            print("network down; retrying \(item.0.id) in 60s"); fflush(stdout)
                            try? await Task.sleep(for: .seconds(60))
                            result = await alignOne(item.0, series: item.1, engine: engine)
                        }
                        if let data = try? encoder.encode(result) {
                            try? data.write(to: resultURL(item.0.id), options: .atomic)
                        }
                        let elapsed = Int(Date().timeIntervalSince(started))
                        let rate = Double(index + 1) / max(1, Double(elapsed))
                        let eta = Int(Double(total - index - 1) / max(rate, 0.0001))
                        let line: String
                        if let error = result.error {
                            line = "FAILED \(error)"
                        } else {
                            let matched = result.starts?.compactMap { $0 }.count ?? 0
                            line = "\(result.source ?? "?") \(Int(result.duration ?? 0))s words=\(result.words ?? 0) matched=\(matched)/\(result.paragraphCount ?? 0) \(result.seconds ?? 0)s"
                        }
                        print("[\(index + 1)/\(total) w\(worker) eta \(eta / 3600)h\(String(format: "%02d", (eta % 3600) / 60))m] \(item.0.id) \(line)")
                        fflush(stdout)
                    }
                }
            }
        }
        try merge()
    }

    actor WorkQueue {
        private var items: [(CatalogDiscourse, SeriesInfo)]
        private var cursor = 0
        init(_ items: [(CatalogDiscourse, SeriesInfo)]) { self.items = items }
        func next() -> (Int, (CatalogDiscourse, SeriesInfo))? {
            guard cursor < items.count else { return nil }
            defer { cursor += 1 }
            return (cursor, items[cursor])
        }
    }

    static func alignOne(_ discourse: CatalogDiscourse, series: SeriesInfo, engine: SpeechWordRecognizer.Engine) async -> Result {
        var result = Result(id: discourse.id, createdAt: Date())
        let started = Date()
        do {
            let paragraphs = try await paragraphs(for: discourse)
            result.paragraphCount = paragraphs.count
            guard !paragraphs.isEmpty else { throw ToolError.blankTranscript }
            let (audio, source) = try await downloadAudio(discourse)
            defer { try? FileManager.default.removeItem(at: audio) }
            result.source = source
            let file = try AVAudioFile(forReading: audio)
            result.duration = Double(file.length) / file.processingFormat.sampleRate
            let words = try await SpeechWordRecognizer.recognizeWords(in: audio, engine: engine) { _ in }
            result.words = words.count
            result.engine = engine.name
            let starts = TranscriptAligner.paragraphStarts(paragraphs: paragraphs, words: words)
            guard starts.contains(where: { $0 != nil }) else { throw ToolError.noLandmarks(words: words.count) }
            result.starts = starts
        } catch {
            result.error = "\(error)"
        }
        result.seconds = Int(Date().timeIntervalSince(started))
        return result
    }

    enum ToolError: Error, CustomStringConvertible {
        case blankTranscript
        case noLandmarks(words: Int)
        case noAudio([String])
        case notAudio(String)

        var description: String {
            switch self {
            case .blankTranscript: return "transcript parsed to no paragraphs"
            case .noLandmarks(let words): return "no landmarks (\(words) words recognised)"
            case .noAudio(let reasons): return "audio unavailable: \(reasons.joined(separator: "; "))"
            case .notAudio(let type): return "response was \(type), not audio"
            }
        }
    }

    /// The transcript exactly as the app parses it, from the crawl cache when
    /// present so a full run does not hit the site 5,000 times.
    static func paragraphs(for discourse: CatalogDiscourse) async throws -> [Transcript.Paragraph] {
        guard let entry = TranscriptCatalog.entry(for: discourse.id) else { throw ToolError.blankTranscript }
        let cached = crawlDir.appendingPathComponent("desc-\(entry.id).json")
        if let data = try? Data(contentsOf: cached), let html = TranscriptFetcher.description(fromAPIResponse: data) {
            return TranscriptParser.paragraphs(fromHTML: html)
        }
        let html = try await TranscriptFetcher.fetchDescriptionHTML(for: entry, allowsCellular: true)
        return TranscriptParser.paragraphs(fromHTML: html)
    }

    /// Archive mirror first, then oshoworld: the same order and the same URLs
    /// the app downloads from, so the aligned file is the one listeners hold.
    static func downloadAudio(_ discourse: CatalogDiscourse) async throws -> (URL, String) {
        var sources: [(URL, String)] = []
        if let archive = ArchiveCatalog.audioURL(for: discourse) { sources.append((archive, "archive")) }
        if let osho = URL(string: discourse.audioURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? discourse.audioURL) {
            sources.append((osho, "oshoworld"))
        }
        var reasons: [String] = []
        for (url, name) in sources {
            do {
                var request = URLRequest(url: url, timeoutInterval: 180)
                request.setValue("OshoDiscourses-AlignTranscripts/1.0", forHTTPHeaderField: "User-Agent")
                let (temp, response) = try await URLSession.shared.download(for: request)
                let http = response as? HTTPURLResponse
                guard http?.statusCode == 200 else {
                    try? FileManager.default.removeItem(at: temp)
                    reasons.append("\(name) HTTP \(http?.statusCode ?? -1)"); continue
                }
                let type = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
                guard !type.contains("text/html") else {
                    try? FileManager.default.removeItem(at: temp)
                    reasons.append("\(name) served HTML"); continue
                }
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent("align-\(UUID().uuidString).mp3")
                try FileManager.default.moveItem(at: temp, to: dest)
                return (dest, name)
            } catch {
                reasons.append("\(name) \(error.localizedDescription)")
            }
        }
        throw ToolError.noAudio(reasons)
    }

    // MARK: - Merge & report

    static func merge() throws {
        var catalog: [String: String] = [:]
        var failures = 0
        for file in try resultFiles() {
            guard let data = try? Data(contentsOf: file), let r = try? decoder.decode(Result.self, from: data) else { continue }
            if r.isFailure { failures += 1; continue }
            guard let count = r.paragraphCount, let duration = r.duration, let starts = r.starts, starts.count == count else { continue }
            catalog[r.id] = AlignmentCatalog.encode(AlignmentCatalog.Entry(paragraphCount: count, duration: duration, starts: starts))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(catalog)
        try data.write(to: catalogURL, options: .atomic)
        print("merged \(catalog.count) alignments (\(failures) failures) -> \(catalogURL.path) (\(data.count / 1024) KB)")
    }

    static func report() throws {
        var ok = 0, failed = 0, matched = 0, paragraphs = 0
        var byLanguage: [String: (Int, Int)] = [:]
        var errors: [String: Int] = [:]
        for file in try resultFiles() {
            guard let data = try? Data(contentsOf: file), let r = try? decoder.decode(Result.self, from: data) else { continue }
            let language = r.id.hasPrefix("hindi-") ? "hindi" : "english"
            if let error = r.error {
                failed += 1
                let key = String(error.prefix(60))
                errors[key, default: 0] += 1
                byLanguage[language, default: (0, 0)].1 += 1
            } else {
                ok += 1
                matched += r.starts?.compactMap { $0 }.count ?? 0
                paragraphs += r.paragraphCount ?? 0
                byLanguage[language, default: (0, 0)].0 += 1
            }
        }
        print("aligned \(ok), failed \(failed); paragraphs matched \(matched)/\(paragraphs) (\(paragraphs > 0 ? matched * 100 / paragraphs : 0)%)")
        for (language, counts) in byLanguage.sorted(by: { $0.key < $1.key }) { print("  \(language): ok \(counts.0) failed \(counts.1)") }
        for (error, n) in errors.sorted(by: { $0.value > $1.value }).prefix(15) { print("  \(n)x \(error)") }
    }

    static func resultFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: resultsDir.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: resultsDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
    }
}
