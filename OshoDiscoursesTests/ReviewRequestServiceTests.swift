import Foundation
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

    @MainActor
    @Test func recordsVersionAndCooldownBeforeRequestingAndSuppressesReentry() {
        withReview { defaults, engagement, clock in
            var requests = 0
            let requested = attempt(defaults, engagement) {
                requests += 1
                #expect(defaults.string(forKey: "review.lastPromptedVersion") == "2.0")
                #expect(engagement.history.lastRatingAttempt == clock.date)
                #expect(!attempt(defaults, engagement) { requests += 1 })
            }
            #expect(requested)
            #expect(requests == 1)
        }
    }

    @MainActor
    @Test func existingVersionKeyStillPreventsARequestWithoutATimestamp() {
        withReview { defaults, engagement, _ in
            defaults.set("2.0", forKey: "review.lastPromptedVersion")
            #expect(!attempt(defaults, engagement) { Issue.record("Repeated legacy version") })
            #expect(engagement.history.lastRatingAttempt == nil)
            #expect(attempt(defaults, engagement, version: "2.1") {})
        }
    }

    @MainActor
    @Test func newVersionDoesNotBypassNinetyDayCooldownAcrossRelaunch() {
        withReview { defaults, engagement, clock in
            let firstAttempt = clock.date
            #expect(attempt(defaults, engagement) {})
            let relaunched = EngagementService(defaults: defaults, now: { clock.date })
            clock.date = firstAttempt.addingTimeInterval(90 * 86_400 - 1)
            #expect(!attempt(defaults, relaunched, version: "2.1") { Issue.record("Early rating") })
            clock.date = firstAttempt.addingTimeInterval(90 * 86_400)
            #expect(!attempt(defaults, relaunched) { Issue.record("Repeated version") })
            #expect(attempt(defaults, relaunched, version: "2.1") {})
        }
    }

    @MainActor
    @Test func futurePersistedRatingTimestampDoesNotAllowANewVersionRequest() {
        withReview { defaults, _, clock in
            defaults.set(clock.date.addingTimeInterval(86_400), forKey: EngagementService.Keys.lastRatingAttempt)
            let relaunched = EngagementService(defaults: defaults, now: { clock.date })
            #expect(!attempt(defaults, relaunched) { Issue.record("Future timestamp bypass") })
            #expect(defaults.string(forKey: "review.lastPromptedVersion") == nil)
        }
    }

    @MainActor
    @Test func freshUsersPlaybackSleepAndBackgroundDoNotConsumeTheRequest() {
        withReview { defaults, engagement, _ in
            #expect(!attempt(defaults, engagement, activeDays: 2) { Issue.record("Fresh user") })
            #expect(!attempt(defaults, engagement, isForeground: false) { Issue.record("Background request") })
            #expect(!attempt(defaults, engagement, isPlaying: true) { Issue.record("Playback request") })
            #expect(!attempt(defaults, engagement, sleepTimerArmed: true) { Issue.record("Sleep request") })
            #expect(engagement.history.lastRatingAttempt == nil)
            #expect(defaults.string(forKey: "review.lastPromptedVersion") == nil)
            #expect(attempt(defaults, engagement) {})
        }
    }

    @MainActor
    @Test func visibleSupportAndRecentSupportExposureBlockNativeRequests() {
        withReview { defaults, engagement, clock in
            let owner = UUID()
            let context = EngagementService.SupportContext(
                activeDays: 7, totalListening: 7_200, subscriptionStatus: .notSubscribed,
                isForeground: true, isHomeVisible: true
            )
            #expect(engagement.beginSupportPresentation(owner: owner, context: context))
            #expect(!attempt(defaults, engagement) { Issue.record("Paired prompts") })
            #expect(engagement.recordSupportExposure(owner: owner, context: context))
            engagement.endSupportPresentation(owner: owner)
            clock.date = clock.date.addingTimeInterval(14 * 86_400 - 1)
            #expect(!attempt(defaults, engagement) { Issue.record("Too close to support") })
            #expect(defaults.string(forKey: "review.lastPromptedVersion") == nil)
            clock.date = clock.date.addingTimeInterval(1)
            #expect(attempt(defaults, engagement) {})
        }
    }

    @MainActor
    private func attempt(
        _ defaults: UserDefaults,
        _ engagement: EngagementService,
        version: String = "2.0",
        activeDays: Int = 3,
        isForeground: Bool = true,
        isPlaying: Bool = false,
        sleepTimerArmed: Bool = false,
        request: () -> Void
    ) -> Bool {
        ReviewRequestService.attemptReview(
            activeDays: activeDays, currentVersion: version, defaults: defaults, engagement: engagement,
            isForeground: isForeground, isPlaying: isPlaying, sleepTimerArmed: sleepTimerArmed, request: request
        )
    }

    @MainActor
    private func withReview(_ body: @MainActor (UserDefaults, EngagementService, ReviewTestClock) -> Void) {
        let suite = "ReviewRequestServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = ReviewTestClock()
        body(defaults, EngagementService(defaults: defaults, now: { clock.date }), clock)
    }
}

@MainActor
private final class ReviewTestClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
}
