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
    /// When on, the accent color advances to a new palette color each day.
    /// Picking a color manually in Settings turns this off and pins that color.
    var dailyAccentShuffle: Bool {
        didSet { defaults.set(dailyAccentShuffle, forKey: Keys.dailyAccentShuffle) }
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
    var autoPlayNext: Bool {
        didSet { defaults.set(autoPlayNext, forKey: Keys.autoPlayNext) }
    }
    /// When false (default), downloads only run on Wi-Fi. Guards against Smart
    /// Download silently pulling ~20–30 MB discourses over cellular.
    var allowCellularDownloads: Bool {
        didSet { defaults.set(allowCellularDownloads, forKey: Keys.allowCellularDownloads) }
    }
    var noiseReduction: Bool {
        didSet { defaults.set(noiseReduction, forKey: Keys.noiseReduction) }
    }
    var denoiseStrength: String {
        didSet { defaults.set(denoiseStrength, forKey: Keys.denoiseStrength) }
    }
    /// Preferred playback speed (0.5–2.0). Persisted so the player honors the
    /// listener's chosen speed across launches instead of resetting to 1.0.
    /// The in-player speed picker writes back here via AudioPlayerService.setRate.
    var defaultPlaybackRate: Double {
        didSet { defaults.set(defaultPlaybackRate, forKey: Keys.defaultPlaybackRate) }
    }

    // Computed helpers for backward compat with views
    var hideHindi: Bool { languageFilter == .english }
    var hideEnglish: Bool { languageFilter == .hindi }

    /// The accent color actually used app-wide. When daily shuffle is on, it's a
    /// deterministic function of the calendar day (cycles through the palette, a
    /// different color each day, no consecutive repeats); otherwise the user's
    /// pinned `accentTheme`. Deterministic so every view agrees within a day.
    var effectiveAccentTheme: AccentTheme {
        guard dailyAccentShuffle else { return accentTheme }
        return Self.shuffledTheme(forDaysSinceEpoch: Self.daysSinceEpoch())
    }

    /// Maps a day index to a palette color by cycling through all cases in order.
    static func shuffledTheme(forDaysSinceEpoch day: Int) -> AccentTheme {
        let all = AccentTheme.allCases
        let index = ((day % all.count) + all.count) % all.count  // safe for negatives
        return all[index]
    }

    /// Whole days between the reference date and now, in the current calendar.
    private static func daysSinceEpoch() -> Int {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date(timeIntervalSince1970: 0))
        let today = cal.startOfDay(for: Date())
        return cal.dateComponents([.day], from: start, to: today).day ?? 0
    }

    enum Appearance: String, CaseIterable, Sendable {
        case system, dark, light
    }

    // MARK: - Private

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let appearance = "settings.appearance"
        static let accentTheme = "settings.accentTheme"
        static let dailyAccentShuffle = "settings.dailyAccentShuffle"
        static let languageFilter = "settings.languageFilter"
        static let smartDownload = "settings.smartDownload"
        static let smartDelete = "settings.smartDelete"
        static let autoPlayNext = "settings.autoPlayNext"
        static let allowCellularDownloads = "settings.allowCellularDownloads"
        static let noiseReduction = "settings.noiseReduction"
        static let denoiseStrength = "settings.denoiseStrength"
        static let defaultPlaybackRate = "settings.defaultPlaybackRate"
    }

    private init() {
        let d = UserDefaults.standard

        d.register(defaults: [
            Keys.smartDownload: true,
            Keys.smartDelete: false,
            Keys.autoPlayNext: true,
            Keys.allowCellularDownloads: false,
            Keys.noiseReduction: false,
            Keys.denoiseStrength: "medium",
            Keys.defaultPlaybackRate: 1.0,
            Keys.dailyAccentShuffle: false,
        ])

        self.appearance = Appearance(rawValue: d.string(forKey: Keys.appearance) ?? "") ?? .system
        self.accentTheme = AccentTheme(rawValue: d.string(forKey: Keys.accentTheme) ?? "") ?? .purple
        self.dailyAccentShuffle = d.bool(forKey: Keys.dailyAccentShuffle)
        self.languageFilter = LanguageFilter(rawValue: d.string(forKey: Keys.languageFilter) ?? "") ?? .both
        self.smartDownload = d.bool(forKey: Keys.smartDownload)
        self.smartDelete = d.bool(forKey: Keys.smartDelete)
        self.autoPlayNext = d.bool(forKey: Keys.autoPlayNext)
        self.allowCellularDownloads = d.bool(forKey: Keys.allowCellularDownloads)
        self.noiseReduction = d.bool(forKey: Keys.noiseReduction)
        self.denoiseStrength = d.string(forKey: Keys.denoiseStrength) ?? "medium"
        self.defaultPlaybackRate = d.double(forKey: Keys.defaultPlaybackRate)
    }
}

extension Notification.Name {
    static let navigateToSeries = Notification.Name("navigateToSeries")
}

extension Color {
    @MainActor
    static var accent: Color { UserSettings.shared.effectiveAccentTheme.color }
}
