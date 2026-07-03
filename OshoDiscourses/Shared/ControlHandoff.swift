import Foundation

/// Shared contract between the app and the Control Center widget extension.
/// The extension WRITES a request; the app READS and acts on it. No app types,
/// no AVFoundation — just the App Group suite and a few string keys, so this
/// file is safe to compile into the lean widget extension.
enum ControlHandoff {
    static let appGroup = "group.com.agraabhi.oshodiscourses"

    private static let actionKey = "controlHandoff.action"
    private static let tokenKey = "controlHandoff.requestToken"
    private static let lastConsumedTokenKey = "controlHandoff.lastConsumedToken"

    enum Action: String {
        case open     // just bring the app to the foreground
        case resume   // resume the most-recent discourse
    }

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroup)
    }

    /// Called from an extension intent (fires before the app is foregrounded).
    /// A fresh token per request lets the app tell a real tap from a stale flag.
    /// `.open` is a plain launch, so it writes only the dedupe token — no action
    /// for the app to run beyond coming forward.
    static func request(_ action: Action) {
        guard let defaults else { return }
        defaults.set(action.rawValue, forKey: actionKey)
        defaults.set(UUID().uuidString, forKey: tokenKey)
    }

    /// Called by the app on foreground. Returns the pending action exactly once
    /// per token, so a normal cold launch can't replay an old resume request.
    static func consumePendingAction() -> Action? {
        guard let defaults,
              let raw = defaults.string(forKey: actionKey),
              let action = Action(rawValue: raw),
              let token = defaults.string(forKey: tokenKey)
        else { return nil }

        if defaults.string(forKey: lastConsumedTokenKey) == token {
            return nil   // already handled this request
        }
        defaults.set(token, forKey: lastConsumedTokenKey)
        return action
    }
}
