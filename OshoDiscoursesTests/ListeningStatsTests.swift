import Testing
import Foundation
@testable import OshoDiscourses

@Suite(.serialized)
@MainActor
struct ListeningStatsTests {

    @Test func recordListeningTimeAddsToToday() {
        let stats = ListeningStatsService.shared
        let before = stats.totalToday
        stats.recordListeningTime(10)
        #expect(stats.totalToday >= before + 10)
    }

    @Test func totalAllTimeIncludesNewListening() {
        let stats = ListeningStatsService.shared
        let before = stats.totalAllTime
        stats.recordListeningTime(5)
        #expect(stats.totalAllTime >= before + 5)
    }

    @Test func totalLastWeekIncludesToday() {
        let stats = ListeningStatsService.shared
        stats.recordListeningTime(1)
        #expect(stats.totalLastWeek > 0)
    }

    @Test func totalLastMonthIncludesToday() {
        let stats = ListeningStatsService.shared
        stats.recordListeningTime(1)
        #expect(stats.totalLastMonth > 0)
    }

    /// distinctActiveDays counts days with any listening. Recording today keeps
    /// it at least 1, and adding more time the same day doesn't inflate the count
    /// (it's distinct *days*, the review-prompt gate, not sessions).
    @Test func distinctActiveDaysCountsTodayOnce() {
        let stats = ListeningStatsService.shared
        stats.recordListeningTime(3)
        let after = stats.distinctActiveDays
        #expect(after >= 1)
        stats.recordListeningTime(3)  // same day again
        #expect(stats.distinctActiveDays == after)
    }
}
