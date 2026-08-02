import Foundation
import StoreKit
import UIKit

/// Asks for an App Store rating at a good moment: after the listener has used the
/// app on a handful of distinct days, and never more than once per app version.
///
/// We gate on our own version check on top of `requestReview` because iOS already
/// throttles the prompt (at most a few times a year, and silently no-ops if it
/// won't show). Combining "N active days" with "once per version" means we only
/// spend a prompt on someone who's actually a returning listener, right after a
/// satisfying moment (finishing a discourse), not on a cold first launch.
@MainActor
enum ReviewRequestService {

    /// Distinct days of listening before the first ask. Five matches the common
    /// "engaged, not brand-new" bar without waiting so long that goodwill fades.
    nonisolated static let activeDaysThreshold = 5

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
