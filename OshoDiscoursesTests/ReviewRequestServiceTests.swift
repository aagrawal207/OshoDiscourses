import Testing
@testable import OshoDiscourses

struct ReviewRequestServiceTests {
    @Test func requiresThreeActiveDays() {
        #expect(!ReviewRequestService.isEligible(
            activeDays: 2,
            lastPromptedVersion: nil,
            currentVersion: "2.0"
        ))
        #expect(ReviewRequestService.isEligible(
            activeDays: 3,
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

    @Test func pauseAfterTwentyMinutesTodayIsAGoodMoment() {
        #expect(!ReviewRequestService.isGoodPauseMoment(listenedToday: 19 * 60 + 59, sleepTimerWasArmed: false))
        #expect(ReviewRequestService.isGoodPauseMoment(listenedToday: 20 * 60, sleepTimerWasArmed: false))
        #expect(!ReviewRequestService.isGoodPauseMoment(listenedToday: 3 * 3600, sleepTimerWasArmed: true))
    }

    @Test func writeReviewLinkTargetsThisApp() {
        let url = ReviewRequestService.writeReviewURL
        #expect(url.host == "apps.apple.com")
        #expect(url.path.hasSuffix("/id6774409039"))
        #expect(url.query == "action=write-review")
    }

    @Test func manualSeekNearEndIsDetected() {
        #expect(AudioPlayerService.isNearEndSeek(target: 96, duration: 100))
        #expect(!AudioPlayerService.isNearEndSeek(target: 90, duration: 100))
        #expect(!AudioPlayerService.isNearEndSeek(target: 0, duration: 0))
    }
}
