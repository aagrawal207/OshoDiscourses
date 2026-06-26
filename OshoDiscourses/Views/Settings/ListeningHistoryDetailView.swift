import SwiftUI

struct ListeningHistoryDetailView: View {
    @Environment(PlaybackStateService.self) private var playbackState
    private var stats = ListeningStatsService.shared

    private struct HistoryItem: Identifiable {
        let id: String
        let title: String
        let series: String
        let position: TimeInterval
    }

    private var items: [HistoryItem] {
        playbackState.recentlyPlayed.compactMap { discourseID in
            let position = playbackState.getPosition(discourseId: discourseID)
            for series in Catalog.allSeries {
                let discs = Catalog.discourses(for: series)
                if let disc = discs.first(where: { $0.id == discourseID }) {
                    return HistoryItem(
                        id: discourseID,
                        title: disc.displayTitle,
                        series: series.name,
                        position: position
                    )
                }
            }
            return nil
        }
    }

    var body: some View {
        List {
            dailyBreakdownSection
            allItemsSection

        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .navigationTitle("Listening History")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Spacer().frame(height: 70)
        }
    }

    // MARK: - Daily Breakdown

    private var dailyBreakdownSection: some View {
        Section("Daily Log") {
            let history = stats.dailyHistory.reversed().map { $0 }
            if history.isEmpty {
                Text("No data yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(history, id: \.date) { entry in
                    HStack {
                        Text(formatDateLabel(entry.date))
                            .font(.subheadline)
                        Spacer()
                        Text(formatDuration(entry.seconds))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .listRowBackground(Color(.secondarySystemGroupedBackground))
    }

    // MARK: - All Items

    private var allItemsSection: some View {
        Section("All Played Discourses (\(items.count))") {
            if items.isEmpty {
                Text("No listening history yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.subheadline)
                                .lineLimit(1)
                            Text(item.series)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if item.position > 0 {
                            Text(formatDuration(item.position))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(Color.accent)
                        }
                    }
                }
            }
        }
        .listRowBackground(Color(.secondarySystemGroupedBackground))
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hrs = total / 3600
        let mins = (total % 3600) / 60
        if hrs > 0 {
            return "\(hrs)h \(mins)m"
        }
        if mins > 0 {
            return "\(mins)m"
        }
        return "<1m"
    }

    private func formatDateLabel(_ dateStr: String) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        guard let date = fmt.date(from: dateStr) else { return dateStr }

        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }

        let display = DateFormatter()
        display.dateFormat = "EEE, MMM d"
        return display.string(from: date)
    }
}
