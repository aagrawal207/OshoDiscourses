import Testing
@testable import OshoDiscourses

struct ReviewRequestServiceTests {
    @Test func requiresFiveActiveDays() {
        #expect(!ReviewRequestService.isEligible(
            activeDays: 4,
            lastPromptedVersion: nil,
            currentVersion: "2.0"
        ))
        #expect(ReviewRequestService.isEligible(
            activeDays: 5,
            lastPromptedVersion: nil,
            currentVersion: "2.0"
        ))
    }

    @Test func suppressesRepeatForSameVersion() {
        #expect(!ReviewRequestService.isEligible(
            activeDays: 20,
            lastPromptedVersion: "2.0",
            currentVersion: "2.0"
        ))
        #expect(ReviewRequestService.isEligible(
            activeDays: 20,
            lastPromptedVersion: "1.9",
            currentVersion: "2.0"
        ))
    }

    @Test func onlyNaturalIdleCompletionIsAGoodMoment() {
        #expect(ReviewRequestService.isGoodMoment(
            completionWasNatural: true,
            playbackContinues: false,
            sleepTimerWasArmed: false
        ))
        #expect(!ReviewRequestService.isGoodMoment(
            completionWasNatural: false,
            playbackContinues: false,
            sleepTimerWasArmed: false
        ))
        #expect(!ReviewRequestService.isGoodMoment(
            completionWasNatural: true,
            playbackContinues: true,
            sleepTimerWasArmed: false
        ))
        #expect(!ReviewRequestService.isGoodMoment(
            completionWasNatural: true,
            playbackContinues: false,
            sleepTimerWasArmed: true
        ))
    }

    @Test func manualSeekNearEndIsDetected() {
        #expect(AudioPlayerService.isNearEndSeek(target: 96, duration: 100))
        #expect(!AudioPlayerService.isNearEndSeek(target: 90, duration: 100))
        #expect(!AudioPlayerService.isNearEndSeek(target: 0, duration: 0))
    }
}
