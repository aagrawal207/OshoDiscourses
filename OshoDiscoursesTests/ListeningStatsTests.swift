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

    // MARK: - Continuous-listening detection (the 2x-speed undercount bug)
    //
    // The auto-save tick is ~10s of wall time, which covers 10 × rate seconds
    // of media. The old fixed 15s cutoff classified every tick at 1.5x+ speed
    // as a "seek" and recorded nothing — fast listeners had zero stats/streak.

    @Test func normalSpeedTickIsContinuous() {
        #expect(PlaybackStateService.isContinuousListening(delta: 10, rate: 1.0))
    }

    @Test func doubleSpeedTickIsContinuous() {
        // 10s wall-time tick at 2.0x ≈ 20s of media — must count, not be
        // discarded as a seek.
        #expect(PlaybackStateService.isContinuousListening(delta: 20, rate: 2.0))
    }

    @Test func seekIsNotContinuous() {
        #expect(!PlaybackStateService.isContinuousListening(delta: 120, rate: 1.0))
        #expect(!PlaybackStateService.isContinuousListening(delta: 120, rate: 2.0))
    }

    @Test func backwardSeekIsNotContinuous() {
        #expect(!PlaybackStateService.isContinuousListening(delta: -30, rate: 1.0))
    }

    @Test func slowRateKeepsNormalThreshold() {
        // At 0.5x a tick covers ~5s of media; the threshold must not shrink
        // below the 1x window (a slow tick can never overshoot it).
        #expect(PlaybackStateService.isContinuousListening(delta: 12, rate: 0.5))
    }
}
