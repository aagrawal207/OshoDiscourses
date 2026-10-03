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

/// Post-model pause reduction and quiet-speech lift, independent of the model's
/// attenuation limit selected by Noise reduction strength.
enum VoiceFocusPreset: String, CaseIterable, Identifiable, Sendable {
    case focus
    case lift
    case strong

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .focus: return "Natural"
        case .lift: return "Gentle Lift"
        case .strong: return "Extra Lift"
        }
    }

    var detail: String {
        switch self {
        case .focus:
            return "Quieter pauses, with no extra lift for soft speech. Keeps more of the voice’s natural dynamics."
        case .lift:
            return "Brings out quieter words without turning up the whole recording."
        case .strong:
            return "More lift for soft speech and quieter pauses. The voice may sound less natural."
        }
    }
}

enum NoiseReductionMode: String, CaseIterable, Identifiable, Sendable {
    case deepFilterNet
    case rnnoise
    case cadence

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .deepFilterNet: return "Best Quality"
        case .rnnoise: return "Balanced"
        case .cadence: return "Gentle Cleanup"
        }
    }

    var batteryNote: String {
        switch self {
        case .deepFilterNet: return "Uses more battery"
        case .rnnoise: return "Uses less battery than Best Quality"
        case .cadence: return "Lightest on battery"
        }
    }

    var detail: String {
        switch self {
        case .deepFilterNet:
            return "Our recommended cleanup for hiss and background noise."
        case .rnnoise:
            return "Everyday noise reduction with lighter processing. May soften the voice."
        case .cadence:
            return "Reduces hum and noise in pauses. Less effective during speech."
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
    /// Point size of transcript body text, stepped from the reader.
    /// Show each sentence of a transcript on its own line (lyrics style) so the
    /// highlight and anchors point at one sentence; off shows paragraph blocks.
    var transcriptSentenceLayout: Bool {
        didSet { defaults.set(transcriptSentenceLayout, forKey: Keys.transcriptSentenceLayout) }
    }

    var transcriptFontSize: Double {
        didSet { defaults.set(transcriptFontSize, forKey: Keys.transcriptFontSize) }
    }
    /// Experimental: derive paragraph timings from on-device speech recognition
    /// instead of the text-fraction estimate. English only (Apple ships no
    /// on-device Hindi recogniser).
    var transcriptSpeechSync: Bool {
        didSet { defaults.set(transcriptSpeechSync, forKey: Keys.transcriptSpeechSync) }
    }

    static let transcriptFontSizes: [Double] = [15, 17, 19, 21, 24, 28]
    static let defaultTranscriptFontSize: Double = 19

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
        static let transcriptFontSize = "settings.transcriptFontSize"
        static let transcriptSentenceLayout = "settings.transcriptSentenceLayout"
        static let transcriptSpeechSync = "settings.transcriptSpeechSync"
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
            Keys.noiseReductionMode: NoiseReductionMode.deepFilterNet.rawValue,
            Keys.voiceFocusPreset: VoiceFocusPreset.lift.rawValue,
            Keys.defaultPlaybackRate: 1.0,
            Keys.volumeBoost: 2.0,
            Keys.dailyAccentShuffle: false,
            Keys.transcriptFontSize: Self.defaultTranscriptFontSize,
            Keys.transcriptSentenceLayout: true,
            Keys.transcriptSpeechSync: false,
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
        ) ?? .deepFilterNet
        self.voiceFocusPreset = VoiceFocusPreset(
            rawValue: d.string(forKey: Keys.voiceFocusPreset) ?? ""
        ) ?? .lift
        self.defaultPlaybackRate = d.double(forKey: Keys.defaultPlaybackRate)
        self.volumeBoost = d.double(forKey: Keys.volumeBoost)
        self.transcriptFontSize = d.double(forKey: Keys.transcriptFontSize)
        self.transcriptSentenceLayout = d.bool(forKey: Keys.transcriptSentenceLayout)
        self.transcriptSpeechSync = d.bool(forKey: Keys.transcriptSpeechSync)

        // Seed today's shuffled color now that all stored props are set.
        self.shuffledThemeToday = Self.shuffledTheme(forDaysSinceEpoch: Self.daysSinceEpoch())
    }
}

extension Color {
    @MainActor
    static var accent: Color { UserSettings.shared.effectiveAccentTheme.color }
}
