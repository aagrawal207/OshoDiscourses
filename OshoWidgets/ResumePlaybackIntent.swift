import AppIntents

/// Backs the "Resume Discourse" Control Center control. Foregrounds the app and
/// leaves a one-shot request in the shared App Group; the app reads it on
/// becoming active and starts playback there. Audio cannot run in the extension
/// process, so this intent only records intent and hands off — it never touches
/// AVFoundation.
///
/// `openAppWhenRun = true` requires these types to be members of the app target
/// too (it errors inside a pure extension), which is why the file is shared.
struct ResumePlaybackIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Discourse"
    static let description = IntentDescription("Open Discourse Player and resume your last discourse.")

    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        ControlHandoff.request(.resume)
        return .result()
    }
}

/// Backs the "Open Discourse Player" control — just brings the app forward, no
/// playback. Same handoff mechanism; the app consumes `.open` as a no-op beyond
/// foregrounding.
struct OpenAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Discourse Player"
    static let description = IntentDescription("Open Discourse Player.")

    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        ControlHandoff.request(.open)
        return .result()
    }
}
