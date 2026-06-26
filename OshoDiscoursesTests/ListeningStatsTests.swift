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
}
