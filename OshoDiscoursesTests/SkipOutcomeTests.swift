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

    // MARK: - Anchor staleness (the lock-screen "-15 jumped back 2 minutes" bug)
    //
    // A seek whose completion never arrives (app suspended mid-seek, media
    // services reset) used to leave the pending target trusted forever: the
    // clock froze and a later -15 anchored on a position minutes in the past.
    // The anchor must only trust a pending target while it's fresh.

    @Test func freshPendingSeekIsTrustedAsAnchor() {
        // Tap burst: seek to 130 issued 0.1s ago, clock still reads 100.
        let anchor = AudioPlayerService.skipAnchor(
            pendingTarget: 130, pendingAge: 0.1, currentTime: 100
        )
        #expect(anchor == 130)
    }

    @Test func stalePendingSeekFallsBackToLiveClock() {
        // Completion was lost 2 minutes ago; playback continued to 250.
        // -15 must compute 250 - 15, not 130 - 15.
        let anchor = AudioPlayerService.skipAnchor(
            pendingTarget: 130, pendingAge: 120, currentTime: 250
        )
        #expect(anchor == 250)
    }

    @Test func pendingSeekAtExactMaxAgeIsStillTrusted() {
        let maxAge = AudioPlayerService.pendingSeekMaxAge
        let anchor = AudioPlayerService.skipAnchor(
            pendingTarget: 130, pendingAge: maxAge, currentTime: 250
        )
        #expect(anchor == 130)
    }

    @Test func pendingSeekJustPastMaxAgeIsIgnored() {
        let maxAge = AudioPlayerService.pendingSeekMaxAge
        let anchor = AudioPlayerService.skipAnchor(
            pendingTarget: 130, pendingAge: maxAge + 0.01, currentTime: 250
        )
        #expect(anchor == 250)
    }

    @Test func noPendingSeekUsesLiveClock() {
        let anchor = AudioPlayerService.skipAnchor(
            pendingTarget: nil, pendingAge: nil, currentTime: 250
        )
        #expect(anchor == 250)
    }

    @Test func pendingTargetWithoutTimestampIsIgnored() {
        // Defensive: a target with no issue time can't prove freshness — fall
        // back to the clock rather than trust a possibly-ancient value.
        let anchor = AudioPlayerService.skipAnchor(
            pendingTarget: 130, pendingAge: nil, currentTime: 250
        )
        #expect(anchor == 250)
    }
}
