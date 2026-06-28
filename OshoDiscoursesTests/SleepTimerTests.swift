import Testing
import Foundation
@testable import OshoDiscourses

/// SleepTimerService is a shared singleton, so each test cancels first to start
/// from a known state. These lock down the mode state machine and, critically,
/// that the end-of-discourse mode only fires on `discourseDidFinish()` — never
/// on the countdown path — and vice versa.
@Suite(.serialized)
@MainActor
struct SleepTimerTests {

    @Test func startsOff() {
        let timer = SleepTimerService.shared
        timer.cancel()
        #expect(timer.mode == .off)
        #expect(timer.isActive == false)
        #expect(timer.statusLabel == "Sleep")
    }

    @Test func countdownSetsModeAndRemaining() {
        let timer = SleepTimerService.shared
        timer.cancel()
        timer.start(minutes: 10)
        #expect(timer.mode == .countdown)
        #expect(timer.isActive)
        #expect(timer.remainingTime == 600)
        timer.cancel()
    }

    @Test func endOfDiscourseSetsModeWithNoCountdown() {
        let timer = SleepTimerService.shared
        timer.cancel()
        timer.startUntilEndOfDiscourse()
        #expect(timer.mode == .endOfDiscourse)
        #expect(timer.isActive)
        #expect(timer.remainingTime == 0)
        #expect(timer.statusLabel == "End")
        timer.cancel()
    }

    @Test func discourseDidFinishFiresOnlyInEndOfDiscourseMode() {
        let timer = SleepTimerService.shared

        // Countdown mode: a track finishing should NOT trigger expiry.
        timer.cancel()
        var fired = false
        timer.onExpire = { fired = true }
        timer.start(minutes: 30)
        timer.discourseDidFinish()
        #expect(fired == false)
        #expect(timer.mode == .countdown)
        timer.cancel()

        // End-of-discourse mode: a track finishing fires expiry and resets.
        fired = false
        timer.onExpire = { fired = true }
        timer.startUntilEndOfDiscourse()
        timer.discourseDidFinish()
        #expect(fired == true)
        #expect(timer.mode == .off)

        timer.onExpire = nil
    }

    @Test func discourseDidFinishIsNoopWhenOff() {
        let timer = SleepTimerService.shared
        timer.cancel()
        var fired = false
        timer.onExpire = { fired = true }
        timer.discourseDidFinish()
        #expect(fired == false)
        timer.onExpire = nil
    }

    @Test func cancelResetsEverything() {
        let timer = SleepTimerService.shared
        timer.startUntilEndOfDiscourse()
        timer.cancel()
        #expect(timer.mode == .off)
        #expect(timer.remainingTime == 0)
        #expect(timer.isActive == false)
    }
}
