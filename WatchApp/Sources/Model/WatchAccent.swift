import SwiftUI

/// Mirrors the phone's `AccentTheme` raw values; the watch keeps the last one it was sent.
enum WatchAccent: String, CaseIterable, Sendable {
    case blue, teal, purple, pink, orange, green, indigo, mint

    static let fallback: WatchAccent = .orange

    var color: Color {
        switch self {
        case .blue: .blue
        case .teal: .teal
        case .purple: .purple
        case .pink: .pink
        case .orange: .orange
        case .green: .green
        case .indigo: .indigo
        case .mint: .mint
        }
    }
}

struct WatchAccentStore {
    static let key = "osho.watch.accent"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> WatchAccent {
        defaults.string(forKey: Self.key).flatMap(WatchAccent.init(rawValue:)) ?? .fallback
    }

    /// Unknown or missing names keep the current accent instead of resetting it.
    @discardableResult
    func apply(_ name: String?) -> WatchAccent? {
        guard let name, let accent = WatchAccent(rawValue: name) else { return nil }
        defaults.set(accent.rawValue, forKey: Self.key)
        return accent
    }
}
