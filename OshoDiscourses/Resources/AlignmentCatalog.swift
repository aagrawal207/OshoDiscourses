import Foundation

/// Paragraph start times for transcripts, computed ahead of time by running
/// Apple's speech recognisers over every discourse (`Tools/AlignTranscripts`)
/// and shipped with the app, so the reader's highlight is accurate on any iOS
/// version and in both languages without the device listening to anything.
///
/// One string per discourse keeps the JSON small enough to bundle:
/// `"<paragraphCount>;<duration>;<starts>"`, times in tenths of a second, each
/// start stored as the difference from the previous known one and `-` where
/// the aligner found no confident match (the sync model interpolates those).
enum AlignmentCatalog {

    struct Entry: Equatable, Sendable {
        let paragraphCount: Int
        /// Length of the recording the alignment was made against.
        let duration: TimeInterval
        /// One per paragraph; nil where no landmark fell inside it.
        let starts: [TimeInterval?]

        var matchedCount: Int { starts.compactMap { $0 }.count }

        /// A shipped alignment applies only to the same paragraph split and the
        /// same recording. Files differing by a trimmed intro would shift every
        /// paragraph, which is worse than the estimate.
        func matches(paragraphCount: Int, duration: TimeInterval) -> Bool {
            self.paragraphCount == paragraphCount && starts.count == paragraphCount
                && abs(self.duration - duration) <= Self.durationTolerance
        }

        static let durationTolerance: TimeInterval = 2.5
    }

    private static let encoded: [String: String] = {
        guard let url = Bundle.main.url(forResource: "AlignmentCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            print("[AlignmentCatalog] AlignmentCatalog.json missing — falling back to estimates")
            return [:]
        }
        return decoded
    }()

    static var count: Int { encoded.count }

    static func hasAlignment(_ discourseID: String) -> Bool {
        encoded[discourseID] != nil
    }

    static func entry(for discourseID: String) -> Entry? {
        encoded[discourseID].flatMap(decode)
    }

    // MARK: - Wire format

    static func encode(_ entry: Entry) -> String {
        var previous = 0
        let tokens = entry.starts.map { start -> String in
            guard let start else { return "-" }
            let tenths = Int((start * 10).rounded())
            defer { previous = tenths }
            return String(tenths - previous)
        }
        return "\(entry.paragraphCount);\(Int((entry.duration * 10).rounded()));\(tokens.joined(separator: ","))"
    }

    static func decode(_ string: String) -> Entry? {
        let fields = string.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count == 3,
              let paragraphCount = Int(fields[0]),
              let durationTenths = Int(fields[1]) else { return nil }
        var starts: [TimeInterval?] = []
        starts.reserveCapacity(paragraphCount)
        var previous = 0
        if !fields[2].isEmpty {
            for token in fields[2].split(separator: ",", omittingEmptySubsequences: false) {
                if token == "-" { starts.append(nil); continue }
                guard let delta = Int(token) else { return nil }
                previous += delta
                starts.append(Double(previous) / 10)
            }
        }
        guard starts.count == paragraphCount else { return nil }
        return Entry(paragraphCount: paragraphCount, duration: Double(durationTenths) / 10, starts: starts)
    }
}
