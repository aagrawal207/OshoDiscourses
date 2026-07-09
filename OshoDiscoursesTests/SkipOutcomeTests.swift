import Testing
@testable import OshoDiscourses

/// The pure skip arithmetic behind the lock-screen / notification +30 / -15
/// controls. Two things broke in practice and are pinned here:
///
/// 1. **Accumulation.** Rapid taps must advance from the *pending seek target*,
///    not the player's lagging clock, so N taps of +30 advance N×30. The service
///    feeds `skipAnchor` (= pendingSeekTarget ?? currentTime) as `anchor`; these
///    tests simulate the burst by chaining the anchor forward.
/// 2. **duration == 0 guard.** When duration isn't known yet, a forward skip must
///    NOT report `.finish` (which would mark the talk complete and, with Smart
///    Delete on, delete the download). It must just seek.
///
/// The in-flight-seek *race* itself needs a live player; that's out of scope for
/// a pure test. This covers the decision logic that the fix hinges on.
struct SkipOutcomeTests {

    // MARK: - Forward accumulation

    @Test func twoForwardSkipsAccumulate() {
        // First tap from 100s in a 3600s talk.
        let first = AudioPlayerService.skipForwardOutcome(anchor: 100, seconds: 30, duration: 3600)
        #expect(first == .seek(130))

        // Second tap fires before the first seek lands: anchor is the pending
        // target (130), NOT the stale clock (still ~100). Must reach 160, not 130.
        let second = AudioPlayerService.skipForwardOutcome(anchor: 130, seconds: 30, duration: 3600)
        #expect(second == .seek(160))
    }

    @Test func forwardSkipAdvancesByInterval() {
        let outcome = AudioPlayerService.skipForwardOutcome(anchor: 0, seconds: 30, duration: 600)
        #expect(outcome == .seek(30))
    }

    // MARK: - End-of-track handoff

    @Test func forwardSkipNearEndFinishes() {
        // 1s from the end (3599 + 30 >= 3600 - 1) → finish.
        let outcome = AudioPlayerService.skipForwardOutcome(anchor: 3599, seconds: 30, duration: 3600)
        #expect(outcome == .finish)
    }

    @Test func forwardSkipJustShyOfEndSeeks() {
        // 3560 + 30 = 3590, and 3590 < 3600 - 1 = 3599 → seek, don't finish.
        let outcome = AudioPlayerService.skipForwardOutcome(anchor: 3560, seconds: 30, duration: 3600)
        #expect(outcome == .seek(3590))
    }

    // MARK: - duration == 0 guard (the premature-finish bug)

    @Test func forwardSkipWithUnknownDurationSeeksNotFinishes() {
        // duration 0 = not ready. Must advance, never finish (would mark complete
        // + Smart-Delete the download).
        let outcome = AudioPlayerService.skipForwardOutcome(anchor: 5, seconds: 30, duration: 0)
        #expect(outcome == .seek(35))
    }

    @Test func forwardSkipWithNegativeDurationSeeksNotFinishes() {
        // Defensive: a non-finite duration coerced below zero must not finish.
        let outcome = AudioPlayerService.skipForwardOutcome(anchor: 5, seconds: 30, duration: -1)
        #expect(outcome == .seek(35))
    }

    // MARK: - Backward

    @Test func backwardSkipSubtractsInterval() {
        #expect(AudioPlayerService.skipBackwardTarget(anchor: 100, seconds: 15) == 85)
    }

    @Test func twoBackwardSkipsAccumulate() {
        let first = AudioPlayerService.skipBackwardTarget(anchor: 100, seconds: 15)
        #expect(first == 85)
        let second = AudioPlayerService.skipBackwardTarget(anchor: first, seconds: 15)
        #expect(second == 70)
    }

    @Test func backwardSkipClampsToZero() {
        #expect(AudioPlayerService.skipBackwardTarget(anchor: 10, seconds: 15) == 0)
    }
}
