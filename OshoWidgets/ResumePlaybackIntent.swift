import AppIntents

/// Backs the "Resume Discourse" Control Center control. Foregrounds the app and
/// leaves a one-shot request in the shared App Group; the app reads it on
/// becoming active and starts playback there. Audio cannot run in the extension
/// process, so this intent only records intent and hands off — it never touches
/// AVFoundation.
///
/// `openAppWhenRun = true` requires this type to be a member of the app target
/// too (it errors inside a pure extension), which is why the file is shared.
struct ResumePlaybackIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Discourse"
    static let description = IntentDescription("Open Discourse Player and resume your last discourse.")

    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        ControlHandoff.requestResume()
        return .result()
    }
}
