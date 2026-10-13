import Foundation
import Observation
import os

@Observable
@MainActor
final class EngagementService {
    static let shared = EngagementService(defaults: sharedDefaults)

    private static var sharedDefaults: UserDefaults {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-debugEngagementSuite"), args.indices.contains(index + 1),
           args[index + 1].hasPrefix("EngagementUITests."), let defaults = UserDefaults(suiteName: args[index + 1]) {
            return defaults
        }
        #endif
        return .standard
    }

    nonisolated static let supportActiveDaysThreshold = 7
    nonisolated static let supportListeningThreshold: TimeInterval = 2 * 60 * 60
    nonisolated static let promptCooldown: TimeInterval = 90 * 24 * 60 * 60
    nonisolated static let crossPromptCooldown: TimeInterval = 14 * 24 * 60 * 60

    enum SubscriptionStatus: Equatable {
        case unknown, notSubscribed, subscribed
    }

    struct SupportContext: Equatable {
        var activeDays = 0
        var totalListening: TimeInterval = 0
        var tipCount = 0
        var subscriptionStatus: SubscriptionStatus = .unknown
        var isForeground = false
        var isHomeVisible = false
        var isPlaying = false
        var sleepTimerArmed = false
        var playerPresented = false
        var otherPresentationActive = false
        var storeIsBusy = false
    }

    struct History: Equatable {
        var lastRatingAttempt: Date?
        var lastSupportExposure: Date?
        var supportSnoozedAt: Date?
        var supportOptedOut = false
    }

    enum Keys {
        static let lastRatingAttempt = "review.lastPromptedAt"
        static let lastSupportExposure = "engagement.lastSupportExposureAt"
        static let supportSnoozedAt = "engagement.supportSnoozedAt"
        static let supportOptedOut = "engagement.supportOptedOut"
    }

    private(set) var history: History
    private(set) var supportCardOwner: UUID?
    private(set) var supportSheetOwner: UUID?
    private(set) var externalSupportSheets: Set<UUID> = []
    private(set) var narrationPresentations: Set<UUID> = []
    /// The What's New screen; prompts wait until it closes.
    private(set) var announcementPresentations: Set<UUID> = []
    private var exposedOwner: UUID?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var checkingSupportStatus = false
    private static let log = Logger(subsystem: "com.agraabhi.oshodiscourses", category: "Engagement")

    var isSupportPresentationActive: Bool { supportCardOwner != nil || supportSheetOwner != nil || !externalSupportSheets.isEmpty }
    var isPromptPresentationActive: Bool {
        isSupportPresentationActive || !narrationPresentations.isEmpty || !announcementPresentations.isEmpty
    }

    init(defaults: UserDefaults = .standard, now: @escaping @MainActor () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        history = History(
            lastRatingAttempt: defaults.object(forKey: Keys.lastRatingAttempt) as? Date,
            lastSupportExposure: defaults.object(forKey: Keys.lastSupportExposure) as? Date,
            supportSnoozedAt: defaults.object(forKey: Keys.supportSnoozedAt) as? Date,
            supportOptedOut: defaults.bool(forKey: Keys.supportOptedOut)
        )
    }

    nonisolated static func hasEstablishedUse(_ context: SupportContext) -> Bool {
        context.activeDays >= supportActiveDaysThreshold
            && context.totalListening.isFinite
            && context.totalListening >= supportListeningThreshold
    }

    nonisolated static func isQuietHomeMoment(_ context: SupportContext) -> Bool {
        context.isForeground && context.isHomeVisible && !context.isPlaying
            && !context.sleepTimerArmed && !context.playerPresented
            && !context.otherPresentationActive && !context.storeIsBusy
    }

    nonisolated static func isSupportEligible(context: SupportContext, history: History, now: Date) -> Bool {
        hasEstablishedUse(context) && isQuietHomeMoment(context)
            && context.tipCount == 0 && context.subscriptionStatus == .notSubscribed
            && supportTimingAllows(history, now: now)
    }

    nonisolated static func shouldCheckSupportStatus(context: SupportContext, history: History, now: Date) -> Bool {
        hasEstablishedUse(context) && isQuietHomeMoment(context)
            && context.tipCount == 0 && context.subscriptionStatus == .unknown
            && supportTimingAllows(history, now: now)
    }

    nonisolated static func isRatingEligible(history: History, supportPresentationActive: Bool, now: Date) -> Bool {
        !supportPresentationActive
            && cooldownHasElapsed(since: history.lastRatingAttempt, interval: promptCooldown, now: now)
            && cooldownHasElapsed(since: history.lastSupportExposure, interval: crossPromptCooldown, now: now)
    }

    nonisolated private static func supportTimingAllows(_ history: History, now: Date) -> Bool {
        !history.supportOptedOut
            && cooldownHasElapsed(since: history.lastSupportExposure, interval: promptCooldown, now: now)
            && cooldownHasElapsed(since: history.supportSnoozedAt, interval: promptCooldown, now: now)
            && cooldownHasElapsed(since: history.lastRatingAttempt, interval: crossPromptCooldown, now: now)
    }

    nonisolated private static func cooldownHasElapsed(since date: Date?, interval: TimeInterval, now: Date) -> Bool {
        guard let date else { return true }
        // A clock rollback must not turn a recent attempt into permission to ask again.
        return now.timeIntervalSince(date) >= interval
    }

    func canShowSupportCard(owner: UUID, context: SupportContext) -> Bool {
        guard supportSheetOwner == nil, externalSupportSheets.isEmpty, narrationPresentations.isEmpty,
              announcementPresentations.isEmpty else { return false }
        if let supportCardOwner {
            guard supportCardOwner == owner else { return false }
            // Exposure starts the next cooldown without removing the card being read.
            return Self.hasEstablishedUse(context) && Self.isQuietHomeMoment(context)
                && context.tipCount == 0 && context.subscriptionStatus == .notSubscribed
                && !history.supportOptedOut
        }
        return Self.isSupportEligible(context: context, history: history, now: now())
    }

    @discardableResult
    func beginSupportPresentation(owner: UUID, context: SupportContext) -> Bool {
        guard canShowSupportCard(owner: owner, context: context) else { return false }
        supportCardOwner = owner
        return true
    }

    @discardableResult
    func recordSupportExposure(owner: UUID, context: SupportContext) -> Bool {
        guard supportCardOwner == owner, canShowSupportCard(owner: owner, context: context) else { return false }
        guard exposedOwner != owner else { return true }
        let date = now()
        defaults.set(date, forKey: Keys.lastSupportExposure)
        history.lastSupportExposure = date
        exposedOwner = owner
        Self.log.info("Support outcome=shown")
        return true
    }

    func endSupportPresentation(owner: UUID) {
        guard supportCardOwner == owner else { return }
        supportCardOwner = nil
        exposedOwner = nil
    }

    func dismissSupport(owner: UUID, context: SupportContext, permanently: Bool) {
        guard recordSupportExposure(owner: owner, context: context) else { return }
        if permanently {
            defaults.set(true, forKey: Keys.supportOptedOut)
            history.supportOptedOut = true
            Self.log.info("Support outcome=opted_out")
        } else {
            let date = now()
            defaults.set(date, forKey: Keys.supportSnoozedAt)
            history.supportSnoozedAt = date
            Self.log.info("Support outcome=snoozed")
        }
        endSupportPresentation(owner: owner)
    }

    @discardableResult
    func openSupportSheet(owner: UUID, context: SupportContext) -> Bool {
        guard recordSupportExposure(owner: owner, context: context) else { return false }
        supportSheetOwner = owner
        Self.log.info("Support outcome=opened")
        endSupportPresentation(owner: owner)
        return true
    }

    func endSupportSheet(owner: UUID) {
        if supportSheetOwner == owner { supportSheetOwner = nil }
    }

    func registerSupportSheet(owner: UUID) {
        externalSupportSheets.insert(owner)
    }

    func unregisterSupportSheet(owner: UUID) {
        externalSupportSheets.remove(owner)
    }

    func registerNarrationPresentation(owner: UUID) {
        narrationPresentations.insert(owner)
        if narrationPresentations.count == 1 { Self.log.debug("Narration presentation outcome=active") }
    }

    func registerAnnouncement(owner: UUID) { announcementPresentations.insert(owner) }

    func unregisterAnnouncement(owner: UUID) { announcementPresentations.remove(owner) }

    func unregisterNarrationPresentation(owner: UUID) {
        let removed = narrationPresentations.remove(owner) != nil
        if removed && narrationPresentations.isEmpty { Self.log.debug("Narration presentation outcome=inactive") }
    }

    @discardableResult
    func recordRatingAttemptIfAllowed() -> Bool {
        guard Self.isRatingEligible(history: history, supportPresentationActive: isPromptPresentationActive, now: now()) else {
            Self.log.debug("Rating outcome=suppressed")
            return false
        }
        let date = now()
        defaults.set(date, forKey: Keys.lastRatingAttempt)
        history.lastRatingAttempt = date
        Self.log.info("Rating outcome=requested")
        return true
    }

    func refreshSupportStatusIfNeeded(context: SupportContext, refresh: @MainActor () async -> Void) async {
        guard !checkingSupportStatus, narrationPresentations.isEmpty, announcementPresentations.isEmpty,
              Self.shouldCheckSupportStatus(context: context, history: history, now: now()) else { return }
        checkingSupportStatus = true
        defer { checkingSupportStatus = false }
        await refresh()
    }
}
