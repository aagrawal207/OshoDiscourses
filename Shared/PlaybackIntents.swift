import AppIntents

struct PlaybackToggleIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Toggle Playback"

    @MainActor
    func perform() async throws -> some IntentResult {
        LiveActivityBridge.shared.togglePlayPause?()
        return .result()
    }
}

struct PlaybackSkipForwardIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Skip Forward"

    @MainActor
    func perform() async throws -> some IntentResult {
        LiveActivityBridge.shared.skipForward?()
        return .result()
    }
}

struct PlaybackSkipBackIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Skip Back"

    @MainActor
    func perform() async throws -> some IntentResult {
        LiveActivityBridge.shared.skipBack?()
        return .result()
    }
}

@MainActor
final class LiveActivityBridge {
    static let shared = LiveActivityBridge()
    var togglePlayPause: (() -> Void)?
    var skipForward: (() -> Void)?
    var skipBack: (() -> Void)?
}
