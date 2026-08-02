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

/// The three DeepFilterNet voice-forward variants, chosen by listening tests on
/// Ashtavakra Maha Geeta #5 (aircraft overhead at 40:20). All three run the
/// model at full attenuation and differ only in how hard they duck noise-only
/// frames and whether they lift quiet speech.
enum VoiceFocusPreset: String, CaseIterable, Identifiable, Sendable {
    case focus
    case lift
    case strong

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .focus: return "Focus"
        case .lift: return "Lift"
        case .strong: return "Strong"
        }
    }

    var detail: String {
        switch self {
        case .focus:
            return "Quietens noise between sentences and keeps Osho's natural dynamics. The most transparent option."
        case .lift:
            return "Same noise ducking, and also raises his quieter passages so soft speech stays forward."
        case .strong:
            return "Ducks noise hardest and lifts quiet speech. Clearest over loud interruptions, most likely to sound processed."
        }
    }
}

enum NoiseReductionMode: String, CaseIterable, Identifiable, Sendable {
    case rnnoise
    case cadence
    case deepFilterNet

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rnnoise: return "RNNoise"
        case .cadence: return "Cadence Filter"
        case .deepFilterNet: return "DeepFilterNet"
        }
    }

    var playerLabel: String {
        switch self {
        case .rnnoise: return "RNNoise"
        case .cadence: return "Cadence"
        case .deepFilterNet: return "DeepFilter"
        }
    }

    /// One-word category shown under the name in the player picker.
    var shortDescriptor: String {
        switch self {
        case .rnnoise: return "Neural"
        case .cadence: return "Hum + pauses"
        case .deepFilterNet: return "Neural, full-band"
        }
    }

    var detail: String {
        switch self {
        case .rnnoise:
            return "General-purpose neural speech denoising. Removes more varied noise, but can soften the voice."
        case .cadence:
            return "Targets electrical hum and gently lowers hiss during long pauses while preserving speech."
        case .deepFilterNet:
            return "The strongest option. A 48 kHz neural model that also removes steady tape hiss and room tone, at a higher battery cost."
        }
    }
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
        didSet {
            defaults.set(dailyAccentShuffle, forKey: Keys.dailyAccentShuffle)
            refreshShuffledTheme()  // flip the observable color the moment it toggles
        }
    }

    /// Today's shuffled color, held as a real observable property so views update
    /// when it changes. It can't be a pure computed value off `Date()` — the clock
    /// isn't observable, so SwiftUI would never see the day roll over. Recomputed
    /// at launch and on foreground via `refreshShuffledTheme()`.
    private(set) var shuffledThemeToday: AccentTheme = .blue
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
    var noiseReductionMode: NoiseReductionMode {
        didSet { defaults.set(noiseReductionMode.rawValue, forKey: Keys.noiseReductionMode) }
    }
    /// Which voice-forward variant DeepFilterNet uses. Persisted so an A/B
    /// comparison across discourses survives relaunches.
    var voiceFocusPreset: VoiceFocusPreset {
        didSet { defaults.set(voiceFocusPreset.rawValue, forKey: Keys.voiceFocusPreset) }
    }
    /// Preferred playback speed (0.5–2.0). Persisted so the player honors the
    /// listener's chosen speed across launches instead of resetting to 1.0.
    /// The in-player speed picker writes back here via AudioPlayerService.setRate.
    var defaultPlaybackRate: Double {
        didSet { defaults.set(defaultPlaybackRate, forKey: Keys.defaultPlaybackRate) }
    }
    /// Output gain selected by the Boost control. New installs start at 2x, but
    /// turning Boost off persists so louder recordings are not forced back on.
    var volumeBoost: Double {
        didSet { defaults.set(volumeBoost, forKey: Keys.volumeBoost) }
    }

    // Computed helpers for backward compat with views
    var hideHindi: Bool { languageFilter == .english }
    var hideEnglish: Bool { languageFilter == .hindi }

    /// The accent color actually used app-wide: today's shuffled color when daily
    /// shuffle is on, otherwise the user's pinned `accentTheme`. Both are stored
    /// observable properties, so every view reacts when either changes.
    var effectiveAccentTheme: AccentTheme {
        dailyAccentShuffle ? shuffledThemeToday : accentTheme
    }

    /// Recompute today's shuffled color from the current date. Call at launch and
    /// when returning to the foreground so a day-rollover (or the toggle flipping)
    /// updates the observable property and, with it, the whole UI.
    func refreshShuffledTheme() {
        shuffledThemeToday = Self.shuffledTheme(forDaysSinceEpoch: Self.daysSinceEpoch())
    }

    /// Maps a day index to a palette color by cycling through all cases in order.
    static func shuffledTheme(forDaysSinceEpoch day: Int) -> AccentTheme {
        let all = AccentTheme.allCases
        let index = ((day % all.count) + all.count) % all.count  // safe for negatives
        return all[index]
    }

    /// Whole days between the reference date and now, in the current calendar.
    static func daysSinceEpoch() -> Int {
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
        static let noiseReductionMode = "settings.noiseReductionMode"
        static let voiceFocusPreset = "settings.voiceFocusPreset"
        static let defaultPlaybackRate = "settings.defaultPlaybackRate"
        static let volumeBoost = "settings.volumeBoost"
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
            Keys.noiseReductionMode: NoiseReductionMode.rnnoise.rawValue,
            Keys.voiceFocusPreset: VoiceFocusPreset.focus.rawValue,
            Keys.defaultPlaybackRate: 1.0,
            Keys.volumeBoost: 2.0,
            Keys.dailyAccentShuffle: false,
        ])

        // Default to light on first launch; a stored value always wins.
        self.appearance = Appearance(rawValue: d.string(forKey: Keys.appearance) ?? "") ?? .light
        self.accentTheme = AccentTheme(rawValue: d.string(forKey: Keys.accentTheme) ?? "") ?? .purple
        self.dailyAccentShuffle = d.bool(forKey: Keys.dailyAccentShuffle)
        self.languageFilter = LanguageFilter(rawValue: d.string(forKey: Keys.languageFilter) ?? "") ?? .both
        self.smartDownload = d.bool(forKey: Keys.smartDownload)
        self.smartDelete = d.bool(forKey: Keys.smartDelete)
        self.autoPlayNext = d.bool(forKey: Keys.autoPlayNext)
        self.allowCellularDownloads = d.bool(forKey: Keys.allowCellularDownloads)
        self.noiseReduction = d.bool(forKey: Keys.noiseReduction)
        self.denoiseStrength = d.string(forKey: Keys.denoiseStrength) ?? "medium"
        self.noiseReductionMode = NoiseReductionMode(
            rawValue: d.string(forKey: Keys.noiseReductionMode) ?? ""
        ) ?? .rnnoise
        self.voiceFocusPreset = VoiceFocusPreset(
            rawValue: d.string(forKey: Keys.voiceFocusPreset) ?? ""
        ) ?? .focus
        self.defaultPlaybackRate = d.double(forKey: Keys.defaultPlaybackRate)
        self.volumeBoost = d.double(forKey: Keys.volumeBoost)

        // Seed today's shuffled color now that all stored props are set.
        self.shuffledThemeToday = Self.shuffledTheme(forDaysSinceEpoch: Self.daysSinceEpoch())
    }
}

extension Notification.Name {
    static let navigateToSeries = Notification.Name("navigateToSeries")
}

extension Color {
    @MainActor
    static var accent: Color { UserSettings.shared.effectiveAccentTheme.color }
}
