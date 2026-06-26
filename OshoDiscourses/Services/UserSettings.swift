import Foundation
import SwiftUI
import Observation

enum AccentTheme: String, CaseIterable, Identifiable, Sendable {
    case blue, teal, purple, pink, orange, green, indigo, mint

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .blue: return .blue
        case .teal: return .teal
        case .purple: return .purple
        case .pink: return .pink
        case .orange: return .orange
        case .green: return .green
        case .indigo: return .indigo
        case .mint: return .mint
        }
    }
}

enum LanguageFilter: String, CaseIterable, Sendable {
    case both = "Both"
    case english = "English"
    case hindi = "Hindi"
}

@Observable
@MainActor
final class UserSettings {
    static let shared = UserSettings()

    var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }
    var accentTheme: AccentTheme {
        didSet { defaults.set(accentTheme.rawValue, forKey: Keys.accentTheme) }
    }
    var languageFilter: LanguageFilter {
        didSet { defaults.set(languageFilter.rawValue, forKey: Keys.languageFilter) }
    }
    var smartDownload: Bool {
        didSet { defaults.set(smartDownload, forKey: Keys.smartDownload) }
    }
    var smartDelete: Bool {
        didSet { defaults.set(smartDelete, forKey: Keys.smartDelete) }
    }
    var showPopularEnglish: Bool {
        didSet { defaults.set(showPopularEnglish, forKey: Keys.showPopularEnglish) }
    }
    var showPopularHindi: Bool {
        didSet { defaults.set(showPopularHindi, forKey: Keys.showPopularHindi) }
    }
    var showBeginnerEnglish: Bool {
        didSet { defaults.set(showBeginnerEnglish, forKey: Keys.showBeginnerEnglish) }
    }
    var showBeginnerHindi: Bool {
        didSet { defaults.set(showBeginnerHindi, forKey: Keys.showBeginnerHindi) }
    }
    var autoPlayNext: Bool {
        didSet { defaults.set(autoPlayNext, forKey: Keys.autoPlayNext) }
    }

    // Computed helpers for backward compat with views
    var hideHindi: Bool { languageFilter == .english }
    var hideEnglish: Bool { languageFilter == .hindi }

    enum Appearance: String, CaseIterable, Sendable {
        case system, dark, light
    }

    // MARK: - Private

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let appearance = "settings.appearance"
        static let accentTheme = "settings.accentTheme"
        static let languageFilter = "settings.languageFilter"
        static let smartDownload = "settings.smartDownload"
        static let smartDelete = "settings.smartDelete"
        static let showPopularEnglish = "settings.showPopularEnglish"
        static let showPopularHindi = "settings.showPopularHindi"
        static let showBeginnerEnglish = "settings.showBeginnerEnglish"
        static let showBeginnerHindi = "settings.showBeginnerHindi"
        static let autoPlayNext = "settings.autoPlayNext"
    }

    private init() {
        let d = UserDefaults.standard

        d.register(defaults: [
            Keys.smartDownload: true,
            Keys.smartDelete: false,
            Keys.showPopularEnglish: true,
            Keys.showPopularHindi: true,
            Keys.showBeginnerEnglish: true,
            Keys.showBeginnerHindi: true,
            Keys.autoPlayNext: true,
        ])

        self.appearance = Appearance(rawValue: d.string(forKey: Keys.appearance) ?? "") ?? .system
        self.accentTheme = AccentTheme(rawValue: d.string(forKey: Keys.accentTheme) ?? "") ?? .purple
        self.languageFilter = LanguageFilter(rawValue: d.string(forKey: Keys.languageFilter) ?? "") ?? .both
        self.smartDownload = d.bool(forKey: Keys.smartDownload)
        self.smartDelete = d.bool(forKey: Keys.smartDelete)
        self.showPopularEnglish = d.bool(forKey: Keys.showPopularEnglish)
        self.showPopularHindi = d.bool(forKey: Keys.showPopularHindi)
        self.showBeginnerEnglish = d.bool(forKey: Keys.showBeginnerEnglish)
        self.showBeginnerHindi = d.bool(forKey: Keys.showBeginnerHindi)
        self.autoPlayNext = d.bool(forKey: Keys.autoPlayNext)
    }
}

extension Notification.Name {
    static let navigateToSeries = Notification.Name("navigateToSeries")
}

extension Color {
    @MainActor
    static var accent: Color { UserSettings.shared.accentTheme.color }
}
