import SwiftUI

struct ListeningStatsView: View {
    private var stats = ListeningStatsService.shared
    @Environment(PlaybackStateService.self) private var playbackState

    var body: some View {
        List {
            overviewSection
            breakdownSection
            recentSessionsSection

        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .navigationTitle("Listening Stats")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Spacer().frame(height: 70)
        }
        .onAppear {
            stats.save()
        }
    }

    // MARK: - Overview

    private var completedDiscourses: Int {
        playbackState.completedDiscourseIDs.count
    }

    private var completedSeries: Int {
        Catalog.allSeries.filter { series in
            let discs = Catalog.discourses(for: series)
            return !discs.isEmpty && discs.allSatisfy { playbackState.isCompleted($0.id) }
        }.count
    }

    private var overviewSection: some View {
        Section {
            VStack(spacing: 20) {
                HStack(spacing: 0) {
                    StatCard(
                        label: "All Time",
                        value: formatDuration(stats.totalAllTime),
                        icon: "infinity",
                        color: Color.accent
                    )
                    StatCard(
                        label: "Streak",
                        value: "\(stats.streakDays)d",
                        icon: "flame.fill",
                        color: .orange
                    )
                }
                HStack(spacing: 0) {
                    StatCard(
                        label: "Discourses Done",
                        value: "\(completedDiscourses)",
                        icon: "checkmark.circle.fill",
                        color: .green
                    )
                    StatCard(
                        label: "Series Done",
                        value: "\(completedSeries)",
                        icon: "books.vertical.fill",
                        color: .purple
                    )
                }
            }
            .padding(.vertical, 8)
        }
        .listRowBackground(Color(.secondarySystemGroupedBackground))
    }

    // MARK: - Breakdown

    private var breakdownSection: some View {
        Section("Time Periods") {
            StatRow(label: "Today", time: stats.totalToday)
            StatRow(label: "Last 7 Days", time: stats.totalLastWeek)
            StatRow(label: "Last 30 Days", time: stats.totalLastMonth)
            StatRow(label: "All Time", time: stats.totalAllTime)
        }
        .listRowBackground(Color(.secondarySystemGroupedBackground))
    }

    // MARK: - Recent Sessions

    private var recentSessionsSection: some View {
        Section {
            NavigationLink {
                ListeningHistoryDetailView()
            } label: {
                HStack {
                    Text("Full Listening History")
                    Spacer()
                    Text("\(playbackState.recentlyPlayed.count) items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
}

// MARK: - Stat Card

private struct StatCard: View {
    let label: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)

            Text(value)
                .font(.title.bold())

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Stat Row

private struct StatRow: View {
    let label: String
    let time: TimeInterval

    private var formatted: String {
        let total = Int(time)
        let hrs = total / 3600
        let mins = (total % 3600) / 60
        if hrs > 0 {
            return "\(hrs)h \(mins)m"
        }
        if mins > 0 {
            return "\(mins) min"
        }
        if total > 0 {
            return "<1 min"
        }
        return "—"
    }

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(formatted)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}
