import Foundation
import Testing
@testable import OshoDiscourses

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct EngagementServiceTests {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    private var established: EngagementService.SupportContext {
        .init(
            activeDays: 7,
            totalListening: 7_200,
            subscriptionStatus: .notSubscribed,
            isForeground: true,
            isHomeVisible: true
        )
    }

    @Test func supportRequiresBothSevenListeningDaysAndTwoHours() {
        var context = established
        #expect(eligible(context))
        context.activeDays = 0
        #expect(!eligible(context))
        context.activeDays = 6
        context.totalListening = 100_000
        #expect(!eligible(context))
        context.activeDays = 7
        context.totalListening = 7_199
        #expect(!eligible(context))
        context.activeDays = 100
        #expect(!eligible(context))
        context.totalListening = 7_200
        #expect(eligible(context))
        context.totalListening = .nan
        #expect(!eligible(context))
        context.totalListening = .infinity
        #expect(!eligible(context))
    }

    @Test func contributorsAndUnknownSubscriptionStatusNeverSeeSupport() {
        var context = established
        context.tipCount = 1
        #expect(!eligible(context))
        context.tipCount = 0
        context.subscriptionStatus = .subscribed
        #expect(!eligible(context))
        context.subscriptionStatus = .unknown
        #expect(!eligible(context))
        context.subscriptionStatus = .notSubscribed
        #expect(eligible(context))
    }

    @Test func supportRequiresAnUncoveredIdleForegroundHome() {
        for context in interruptedContexts {
            #expect(!eligible(context))
            #expect(!EngagementService.isQuietHomeMoment(context))
        }
        #expect(eligible(established))
    }

    @Test func exposureAndSnoozeHaveExactNinetyDayBoundaries() {
        for history in [
            EngagementService.History(lastSupportExposure: date),
            EngagementService.History(supportSnoozedAt: date)
        ] {
            #expect(!eligible(established, history: history, now: date.addingTimeInterval(90 * day - 1)))
            #expect(eligible(established, history: history, now: date.addingTimeInterval(90 * day)))
        }
    }

    @Test func ratingHasAnExactNinetyDayBoundary() {
        let history = EngagementService.History(lastRatingAttempt: date)
        #expect(!ratingEligible(history, now: date.addingTimeInterval(90 * day - 1)))
        #expect(ratingEligible(history, now: date.addingTimeInterval(90 * day)))
    }

    @Test func crossPromptSpacingHasAnExactFourteenDayBoundaryInBothDirections() {
        let rating = EngagementService.History(lastRatingAttempt: date)
        #expect(!eligible(established, history: rating, now: date.addingTimeInterval(14 * day - 1)))
        #expect(eligible(established, history: rating, now: date.addingTimeInterval(14 * day)))
        let support = EngagementService.History(lastSupportExposure: date)
        #expect(!ratingEligible(support, now: date.addingTimeInterval(14 * day - 1)))
        #expect(ratingEligible(support, now: date.addingTimeInterval(14 * day)))
    }

    @Test func futureTimestampsFailClosedForOwnAndCrossPromptCooldowns() {
        let future = date.addingTimeInterval(day)
        #expect(!eligible(established, history: .init(lastSupportExposure: future)))
        #expect(!eligible(established, history: .init(supportSnoozedAt: future)))
        #expect(!eligible(established, history: .init(lastRatingAttempt: future)))
        #expect(!ratingEligible(.init(lastRatingAttempt: future)))
        #expect(!ratingEligible(.init(lastSupportExposure: future)))
        #expect(!eligible(established, history: .init(lastSupportExposure: future), now: date.addingTimeInterval(90 * day)))
        #expect(eligible(established, history: .init(lastSupportExposure: future), now: future.addingTimeInterval(90 * day)))
    }

    @Test func claimingACardIsNotAnExposureAndOnlyOneWindowCanClaim() {
        withService { service, _, _ in
            let first = UUID()
            let second = UUID()
            #expect(service.beginSupportPresentation(owner: first, context: established))
            #expect(!service.beginSupportPresentation(owner: second, context: established))
            #expect(service.history.lastSupportExposure == nil)
            #expect(service.isSupportPresentationActive)
            #expect(!service.recordRatingAttemptIfAllowed())
            service.endSupportPresentation(owner: second)
            #expect(service.supportCardOwner == first)
            service.endSupportPresentation(owner: first)
            #expect(!service.isSupportPresentationActive)
            #expect(service.beginSupportPresentation(owner: second, context: established))
        }
    }

    @Test func exposurePersistsBeforeRelaunchWithoutHidingTheVisibleCard() {
        withService { service, defaults, clock in
            let owner = UUID()
            #expect(service.beginSupportPresentation(owner: owner, context: established))
            #expect(service.recordSupportExposure(owner: owner, context: established))
            #expect(service.history.lastSupportExposure == date)
            #expect(defaults.object(forKey: EngagementService.Keys.lastSupportExposure) as? Date == date)
            #expect(service.canShowSupportCard(owner: owner, context: established))
            clock.date = date.addingTimeInterval(day)
            #expect(service.recordSupportExposure(owner: owner, context: established))
            #expect(service.history.lastSupportExposure == date)
            #expect(service.canShowSupportCard(owner: owner, context: established))

            let relaunched = EngagementService(defaults: defaults, now: { clock.date })
            #expect(!relaunched.beginSupportPresentation(owner: UUID(), context: established))
            #expect(!relaunched.recordRatingAttemptIfAllowed())
            service.endSupportPresentation(owner: owner)
            #expect(!service.canShowSupportCard(owner: owner, context: established))
            clock.date = date.addingTimeInterval(90 * day)
            #expect(relaunched.beginSupportPresentation(owner: UUID(), context: established))
        }
    }

    @Test func unexposedCardCanBeOfferedAfterRelaunch() {
        withService { service, defaults, clock in
            #expect(service.beginSupportPresentation(owner: UUID(), context: established))
            let relaunched = EngagementService(defaults: defaults, now: { clock.date })
            #expect(relaunched.beginSupportPresentation(owner: UUID(), context: established))
        }
    }

    @Test func staleOrUnsafeExposureCallbacksDoNotRecordAnything() {
        withService { service, _, _ in
            let owner = UUID()
            #expect(!service.recordSupportExposure(owner: owner, context: established))
            #expect(service.beginSupportPresentation(owner: owner, context: established))
            #expect(!service.recordSupportExposure(owner: UUID(), context: established))
            for context in interruptedContexts {
                #expect(!service.canShowSupportCard(owner: owner, context: context))
                #expect(!service.recordSupportExposure(owner: owner, context: context))
            }
            var contributor = established
            contributor.tipCount = 1
            #expect(!service.canShowSupportCard(owner: owner, context: contributor))
            #expect(!service.recordSupportExposure(owner: owner, context: contributor))
            contributor.tipCount = 0
            contributor.subscriptionStatus = .subscribed
            #expect(!service.canShowSupportCard(owner: owner, context: contributor))
            contributor.subscriptionStatus = .unknown
            #expect(!service.canShowSupportCard(owner: owner, context: contributor))
            #expect(service.history.lastSupportExposure == nil)
        }
    }

    @Test func notNowSnoozesForNinetyDaysFromDismissalAndSurvivesRelaunch() {
        withService { service, defaults, clock in
            let owner = UUID()
            #expect(service.beginSupportPresentation(owner: owner, context: established))
            #expect(service.recordSupportExposure(owner: owner, context: established))
            clock.date = date.addingTimeInterval(day)
            service.dismissSupport(owner: owner, context: established, permanently: false)
            #expect(!service.isSupportPresentationActive)
            #expect(service.history.supportSnoozedAt == clock.date)
            let relaunched = EngagementService(defaults: defaults, now: { clock.date })
            clock.date = date.addingTimeInterval(91 * day - 1)
            #expect(!relaunched.beginSupportPresentation(owner: UUID(), context: established))
            clock.date = date.addingTimeInterval(91 * day)
            #expect(relaunched.beginSupportPresentation(owner: UUID(), context: established))
        }
    }

    @Test func dontAskAgainIsPermanentAcrossRelaunchesButDoesNotDisableRatings() {
        withService { service, defaults, clock in
            let owner = UUID()
            #expect(service.beginSupportPresentation(owner: owner, context: established))
            service.dismissSupport(owner: owner, context: established, permanently: true)
            #expect(service.history.supportOptedOut)
            #expect(service.history.lastSupportExposure == date)
            clock.date = date.addingTimeInterval(365 * day)
            let relaunched = EngagementService(defaults: defaults, now: { clock.date })
            #expect(!relaunched.beginSupportPresentation(owner: UUID(), context: established))
            var unknown = established
            unknown.subscriptionStatus = .unknown
            #expect(!EngagementService.shouldCheckSupportStatus(context: unknown, history: relaunched.history, now: clock.date))
            #expect(relaunched.recordRatingAttemptIfAllowed())
        }
    }

    @Test func staleWindowCannotDismissOrOpenAnotherWindowsCard() {
        withService { service, _, _ in
            let owner = UUID()
            let staleOwner = UUID()
            #expect(service.beginSupportPresentation(owner: owner, context: established))
            service.dismissSupport(owner: staleOwner, context: established, permanently: true)
            #expect(!service.history.supportOptedOut)
            #expect(!service.openSupportSheet(owner: staleOwner, context: established))
            #expect(service.supportCardOwner == owner)
            #expect(service.history.lastSupportExposure == nil)
        }
    }

    @Test func openingSupportRecordsExposureAndKeepsRatingsBlockedUntilSheetCloses() {
        withService { service, _, clock in
            let owner = UUID()
            #expect(service.beginSupportPresentation(owner: owner, context: established))
            #expect(service.openSupportSheet(owner: owner, context: established))
            #expect(service.history.lastSupportExposure == date)
            #expect(service.supportCardOwner == nil)
            #expect(service.supportSheetOwner == owner)
            #expect(!service.beginSupportPresentation(owner: UUID(), context: established))
            clock.date = date.addingTimeInterval(14 * day)
            #expect(!service.recordRatingAttemptIfAllowed())
            service.endSupportSheet(owner: UUID())
            #expect(!service.recordRatingAttemptIfAllowed())
            service.endSupportSheet(owner: owner)
            #expect(service.recordRatingAttemptIfAllowed())
        }
    }

    @Test func anOpenCardBlocksRatingsEvenAfterCrossPromptCooldown() {
        withService { service, _, clock in
            let owner = UUID()
            #expect(service.beginSupportPresentation(owner: owner, context: established))
            #expect(service.recordSupportExposure(owner: owner, context: established))
            clock.date = date.addingTimeInterval(14 * day)
            #expect(!service.recordRatingAttemptIfAllowed())
            service.endSupportPresentation(owner: owner)
            #expect(service.recordRatingAttemptIfAllowed())
        }
    }

    @Test func manuallyOpenedSupportSheetsBlockRatingsAcrossWindows() {
        withService { service, _, _ in
            let first = UUID()
            let second = UUID()
            service.registerSupportSheet(owner: first)
            service.registerSupportSheet(owner: second)
            #expect(!service.recordRatingAttemptIfAllowed())
            #expect(!service.canShowSupportCard(owner: UUID(), context: established))
            service.unregisterSupportSheet(owner: first)
            #expect(!service.recordRatingAttemptIfAllowed())
            service.unregisterSupportSheet(owner: second)
            #expect(service.recordRatingAttemptIfAllowed())
        }
    }

    @Test func ratingAttemptsPersistAcrossRelaunchAndBlockSupportForFourteenDays() {
        withService { service, defaults, clock in
            #expect(service.recordRatingAttemptIfAllowed())
            #expect(service.history.lastRatingAttempt == date)
            let relaunched = EngagementService(defaults: defaults, now: { clock.date })
            #expect(!relaunched.recordRatingAttemptIfAllowed())
            clock.date = date.addingTimeInterval(14 * day - 1)
            #expect(!relaunched.beginSupportPresentation(owner: UUID(), context: established))
            clock.date = date.addingTimeInterval(14 * day)
            #expect(relaunched.canShowSupportCard(owner: UUID(), context: established))
            clock.date = date.addingTimeInterval(90 * day - 1)
            #expect(!relaunched.recordRatingAttemptIfAllowed())
            clock.date = date.addingTimeInterval(90 * day)
            #expect(relaunched.recordRatingAttemptIfAllowed())
        }
    }

    @Test func statusCheckRequiresEstablishedUseWithoutContributionsOrInterruptions() async {
        await withAsyncService { service, _, _ in
            var unknown = established
            unknown.subscriptionStatus = .unknown
            var blocked = interruptedContexts.map { context in
                var context = context
                context.subscriptionStatus = .unknown
                return context
            }
            blocked.append(established)
            var fresh = unknown
            fresh.activeDays = 6
            blocked.append(fresh)
            fresh.activeDays = 7
            fresh.totalListening = 7_199
            blocked.append(fresh)
            var contributor = unknown
            contributor.tipCount = 1
            blocked.append(contributor)
            contributor.tipCount = 0
            contributor.subscriptionStatus = .subscribed
            blocked.append(contributor)
            var calls = 0
            for context in blocked {
                await service.refreshSupportStatusIfNeeded(context: context) { calls += 1 }
            }
            #expect(calls == 0)
            await service.refreshSupportStatusIfNeeded(context: unknown) { calls += 1 }
            #expect(calls == 1)
        }
    }

    @Test func statusCheckRespectsAllPersistedSupportGates() {
        var unknown = established
        unknown.subscriptionStatus = .unknown
        for history in [
            EngagementService.History(lastSupportExposure: date),
            EngagementService.History(supportSnoozedAt: date),
            EngagementService.History(lastRatingAttempt: date),
            EngagementService.History(supportOptedOut: true)
        ] {
            #expect(!EngagementService.shouldCheckSupportStatus(context: unknown, history: history, now: date))
        }
    }

    @Test func concurrentWindowsShareOneInFlightStatusLookupAndCanRetryLater() async {
        await withAsyncService { service, _, _ in
            var unknown = established
            unknown.subscriptionStatus = .unknown
            let entered = TipTestGate()
            let release = TipTestGate()
            var calls = 0
            let checking = Task {
                await service.refreshSupportStatusIfNeeded(context: unknown) {
                    calls += 1
                    entered.open()
                    await release.wait()
                }
            }
            await entered.wait()
            await service.refreshSupportStatusIfNeeded(context: unknown) { calls += 1 }
            #expect(calls == 1)
            release.open()
            await checking.value
            await service.refreshSupportStatusIfNeeded(context: unknown) { calls += 1 }
            #expect(calls == 2)
        }
    }

    private var interruptedContexts: [EngagementService.SupportContext] {
        let flags: [(WritableKeyPath<EngagementService.SupportContext, Bool>, Bool)] = [
            (\.isForeground, false), (\.isHomeVisible, false), (\.isPlaying, true),
            (\.sleepTimerArmed, true), (\.playerPresented, true),
            (\.otherPresentationActive, true), (\.storeIsBusy, true)
        ]
        return flags.map { keyPath, value in
            var context = established
            context[keyPath: keyPath] = value
            return context
        }
    }

    private func eligible(
        _ context: EngagementService.SupportContext,
        history: EngagementService.History = .init(),
        now: Date? = nil
    ) -> Bool {
        EngagementService.isSupportEligible(context: context, history: history, now: now ?? date)
    }

    private func ratingEligible(_ history: EngagementService.History, now: Date? = nil) -> Bool {
        EngagementService.isRatingEligible(history: history, supportPresentationActive: false, now: now ?? date)
    }

    private func withService(_ body: @MainActor (EngagementService, UserDefaults, EngagementTestClock) -> Void) {
        let suite = "EngagementServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = EngagementTestClock(date: date)
        body(EngagementService(defaults: defaults, now: { clock.date }), defaults, clock)
    }

    private func withAsyncService(_ body: @MainActor (EngagementService, UserDefaults, EngagementTestClock) async -> Void) async {
        let suite = "EngagementServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = EngagementTestClock(date: date)
        await body(EngagementService(defaults: defaults, now: { clock.date }), defaults, clock)
    }
}

@MainActor
private final class EngagementTestClock {
    var date: Date

    init(date: Date) { self.date = date }
}
