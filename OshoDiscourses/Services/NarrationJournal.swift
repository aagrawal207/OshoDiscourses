import Foundation
import os

/// A short on-device record of translation runs. iOS gives no callback when it suspends or ends the app
/// in the background, so the last entries before a launch are the only account of why a run stopped.
@MainActor
final class NarrationJournal {
    static let shared = NarrationJournal(
        url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("narration-journal.log")
    )
    private static let log = Logger(subsystem: "com.agraabhi.oshodiscourses", category: "NarrationJournal")
    static let limit = 400

    private let url: URL
    private let clock: () -> Date
    private var loaded: [String]?

    init(url: URL, clock: @escaping () -> Date = Date.init) {
        self.url = url
        self.clock = clock
    }

    var entries: [String] {
        if let loaded { return loaded }
        let lines = (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        loaded = lines
        return lines
    }

    func record(_ event: String) {
        var lines = entries
        lines.append("\(clock().formatted(Date.ISO8601FormatStyle(timeZone: .current))) \(event)")
        if lines.count > Self.limit { lines.removeFirst(lines.count - Self.limit) }
        loaded = lines
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Self.log.error("stage=write outcome=failed")
        }
    }

    /// Type, domain and code only: messages can quote translated text.
    static func describe(_ error: Error) -> String {
        let bridged = error as NSError
        return "\(String(reflecting: type(of: error))) \(bridged.domain)#\(bridged.code)"
    }
}
