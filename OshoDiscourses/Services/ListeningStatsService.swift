import Foundation
import Observation

@Observable
@MainActor
final class ListeningStatsService {
    static let shared = ListeningStatsService()

    private struct DailyEntry: Codable {
        let date: String
        var seconds: TimeInterval
    }

    private var entries: [DailyEntry] = []
    private let fileURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        fileURL = appSupport.appendingPathComponent("listening_stats.json")
        // Migrate from old Documents location if needed
        let oldURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("listening_stats.json")
        if !FileManager.default.fileExists(atPath: fileURL.path),
           FileManager.default.fileExists(atPath: oldURL.path) {
            try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
            try? FileManager.default.moveItem(at: oldURL, to: fileURL)
        }
        load()
    }

    // MARK: - Public API

    func recordListeningTime(_ seconds: TimeInterval) {
        let today = Self.dateString(for: Date())
        if let idx = entries.firstIndex(where: { $0.date == today }) {
            entries[idx].seconds += seconds
        } else {
            entries.append(DailyEntry(date: today, seconds: seconds))
        }
    }

    func save() {
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {}
    }

    // MARK: - iCloud Sync

    /// Export per-day totals as a plain date→seconds map for syncing.
    func syncedDailyStats() -> [String: TimeInterval] {
        var map: [String: TimeInterval] = [:]
        for entry in entries { map[entry.date] = entry.seconds }
        return map
    }

    /// Merge per-day totals from another device. Takes the MAX seconds per day so
    /// the merge is idempotent and converges regardless of write order. (Summing
    /// would double-count every time the same day re-syncs; max can under-count a
    /// day listened on two devices, but never inflates — the safe direction for a
    /// streak.) Returns true if anything changed locally.
    @discardableResult
    func mergeSyncedStats(_ incoming: [String: TimeInterval]) -> Bool {
        var changed = false
        for (date, seconds) in incoming {
            if let idx = entries.firstIndex(where: { $0.date == date }) {
                if seconds > entries[idx].seconds {
                    entries[idx].seconds = seconds
                    changed = true
                }
            } else {
                entries.append(DailyEntry(date: date, seconds: seconds))
                changed = true
            }
        }
        if changed {
            entries.sort { $0.date < $1.date }
            save()
        }
        return changed
    }

    var totalAllTime: TimeInterval {
        entries.reduce(0) { $0 + $1.seconds }
    }

    var totalToday: TimeInterval {
        let today = Self.dateString(for: Date())
        return entries.first(where: { $0.date == today })?.seconds ?? 0
    }

    var totalLastWeek: TimeInterval {
        total(days: 7)
    }

    var totalLastMonth: TimeInterval {
        total(days: 30)
    }

    var streakDays: Int {
        let cal = Calendar.current
        var streak = 0
        var checkDate = Date()

        // If nothing today yet, start checking from yesterday
        let today = Self.dateString(for: checkDate)
        if entries.first(where: { $0.date == today })?.seconds ?? 0 < 60 {
            checkDate = cal.date(byAdding: .day, value: -1, to: checkDate) ?? checkDate
        }

        while true {
            let dateStr = Self.dateString(for: checkDate)
            if let entry = entries.first(where: { $0.date == dateStr }), entry.seconds >= 60 {
                streak += 1
                checkDate = cal.date(byAdding: .day, value: -1, to: checkDate) ?? checkDate
            } else {
                break
            }
        }
        return streak
    }

    var dailyHistory: [(date: String, seconds: TimeInterval)] {
        let last30 = Array(entries.suffix(30))
        return last30.map { ($0.date, $0.seconds) }
    }

    // MARK: - Private

    private func total(days: Int) -> TimeInterval {
        let cal = Calendar.current
        guard let cutoff = cal.date(byAdding: .day, value: -days, to: Date()) else { return 0 }
        let cutoffStr = Self.dateString(for: cutoff)
        return entries
            .filter { $0.date >= cutoffStr }
            .reduce(0) { $0 + $1.seconds }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            entries = try JSONDecoder().decode([DailyEntry].self, from: data)
        } catch {}
    }

    private static let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = .current
        return fmt
    }()

    private static func dateString(for date: Date) -> String {
        dateFormatter.string(from: date)
    }
}
