import Foundation
import StoreKit
import UIKit

/// Asks for an App Store rating at a good moment: after the listener has used the
/// app on a few distinct days, and never more than once per app version.
///
/// iOS throttles the prompt itself; the version gate keeps us from spending it on a
/// cold launch. Good moments are a natural, idle completion or a manual pause after
/// a long listen, both when the listener has already stopped the audio.
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
        guard isGoodPauseMoment(
            listenedToday: ListeningStatsService.shared.totalToday,
            sleepTimerWasArmed: SleepTimerService.shared.isActive
        ) else { return }
        requestReviewIfAppropriate()
    }

    /// Call after a natural high point (e.g. finishing a discourse). Requests a
    /// review only if the listener has enough active days and hasn't already been
    /// asked on this version. Safe to call often — it self-gates.
    static func requestReviewIfAppropriate() {
        guard isEligible(
            activeDays: ListeningStatsService.shared.distinctActiveDays,
            lastPromptedVersion: defaults.string(forKey: lastPromptedVersionKey),
            currentVersion: currentVersion
        ) else { return }

        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else {
            return  // no active scene (e.g. backgrounded) — try again next time
        }

        // Record the attempt before asking: iOS may or may not actually show the
        // dialog, but either way we shouldn't pester on this version again.
        defaults.set(currentVersion, forKey: lastPromptedVersionKey)
        AppStore.requestReview(in: scene)
    }
}
