import Foundation
import StoreKit
import UIKit

/// Native rating requests belong at idle listening breaks, away from support asks.
@MainActor
enum ReviewRequestService {

    /// Distinct days of listening before the first ask. Talks run 60-90 minutes, so
    /// three days is already several hours of returning use.
    nonisolated static let activeDaysThreshold = 3

    /// Listening today before a manual pause counts as a good moment. Few listeners
    /// let a 90-minute talk end with auto-advance off, so completion alone rarely asks.
    nonisolated static let pauseMomentListening: TimeInterval = 20 * 60

    nonisolated static let writeReviewURL =
        URL(string: "https://apps.apple.com/app/id6774409039?action=write-review")!

    private static let defaults = UserDefaults.standard
    private static let lastPromptedVersionKey = "review.lastPromptedVersion"

    private static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    nonisolated static func isEligible(
        activeDays: Int,
        lastPromptedVersion: String?,
        currentVersion: String
    ) -> Bool {
        activeDays >= activeDaysThreshold && lastPromptedVersion != currentVersion
    }

    nonisolated static func isGoodMoment(
        completionWasNatural: Bool,
        playbackContinues: Bool,
        sleepTimerWasArmed: Bool
    ) -> Bool {
        completionWasNatural && !playbackContinues && !sleepTimerWasArmed
    }

    nonisolated static func isGoodPauseMoment(listenedToday: TimeInterval, sleepTimerWasArmed: Bool) -> Bool {
        listenedToday >= pauseMomentListening && !sleepTimerWasArmed
    }

    /// Call after the listener pauses from an on-screen control.
    static func listenerDidPause() {
        guard !AppRuntime.shared.audioPlayer.isPlayingNarration, isGoodPauseMoment(
            listenedToday: ListeningStatsService.shared.totalToday,
            sleepTimerWasArmed: SleepTimerService.shared.isActive
        ) else { return }
        requestReviewIfAppropriate()
    }

    /// Call only after a natural completion or an eligible manual pause.
    static func requestReviewIfAppropriate() {
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else {
            return
        }

        attemptReview(
            activeDays: ListeningStatsService.shared.distinctActiveDays,
            currentVersion: currentVersion,
            defaults: defaults,
            engagement: .shared,
            isForeground: true,
            isPlaying: AppRuntime.shared.audioPlayer.isPlaying,
            sleepTimerArmed: SleepTimerService.shared.isActive,
            isNarration: AppRuntime.shared.audioPlayer.isPlayingNarration
        ) {
            AppStore.requestReview(in: scene)
        }
    }

    @discardableResult
    static func attemptReview(
        activeDays: Int,
        currentVersion: String,
        defaults: UserDefaults,
        engagement: EngagementService,
        isForeground: Bool,
        isPlaying: Bool,
        sleepTimerArmed: Bool,
        isNarration: Bool = false,
        request: () -> Void
    ) -> Bool {
        guard isForeground, !isPlaying, !sleepTimerArmed, !isNarration,
              isEligible(
                activeDays: activeDays,
                lastPromptedVersion: defaults.string(forKey: lastPromptedVersionKey),
                currentVersion: currentVersion
              ), engagement.recordRatingAttemptIfAllowed() else { return false }

        // StoreKit may suppress the dialog; the attempt still consumes both gates.
        defaults.set(currentVersion, forKey: lastPromptedVersionKey)
        request()
        return true
    }
}
