import Foundation
import UIKit

/// Every event the app records. Names follow TelemetryDeck's `Area.event` style.
/// Only `usageSummary`, `listeningTalk` and `TelemetryService.immediateSignals`
/// are sent as signals; the rest are counted into the summary.
enum TelemetrySignal: String, CaseIterable, Sendable {
    case usageSummary = "Usage.summary"
    case listeningTalk = "Listening.talk"

    // One event per talk segment, counted into the summary and that talk's total.
    case listeningSession = "Listening.session"
    case speedChanged = "Playback.speedChanged"
    case playbackFailed = "Playback.failed"
    case sleepTimerStarted = "SleepTimer.started"
    case sleepTimerCancelled = "SleepTimer.cancelled"

    case downloadCompleted = "Download.completed"
    case downloadFailed = "Download.failed"
    case downloadAllRequested = "Download.allRequested"
    case downloadDeleted = "Download.deleted"

    case translationStarted = "Translation.prepareStarted"
    case translationConsent = "Translation.consent"
    case translationFinished = "Translation.prepareFinished"
    case translationDeleted = "Translation.deleted"

    case bookmarkAdded = "Bookmark.added"
    case bookmarkDeleted = "Bookmark.deleted"
    case bookmarkOpened = "Bookmark.opened"

    case transcriptOpened = "Transcript.opened"
    case transcriptSearched = "Transcript.searched"
    case transcriptAction = "Transcript.action"

    case settingChanged = "Settings.changed"
    case librarySearched = "Library.searched"
    case libraryFilterSelected = "Library.filterSelected"
    case seriesOpened = "Series.opened"

    case supportSheetOpened = "Support.sheetOpened"
    case supportPurchase = "Support.purchase"
    case supportPrompt = "Support.prompt"
    case reviewRequested = "Review.requested"

    case carPlayConnected = "CarPlay.connected"
    case watchCommand = "Watch.command"
    case watchTransfer = "Watch.transfer"
    /// A position the Watch reports back after listening without the phone.
    case watchOfflineListening = "Watch.offlineListening"
    case whatsNewShown = "WhatsNew.shown"

    /// Parameters whose values get their own counter in the summary, as
    /// `Signal.parameter.value`. Every value must come from a closed set.
    var countedDimensions: [String] {
        switch self {
        case .usageSummary, .listeningTalk, .listeningSession: return []
        case .speedChanged, .sleepTimerCancelled, .downloadAllRequested, .translationDeleted,
             .bookmarkDeleted, .transcriptSearched, .seriesOpened, .supportSheetOpened,
             .reviewRequested, .whatsNewShown, .supportPurchase:
            return []
        case .playbackFailed: return ["category"]
        case .sleepTimerStarted: return ["option"]
        case .downloadCompleted: return ["origin", "source", "fallback"]
        case .downloadFailed: return ["origin", "category"]
        case .downloadDeleted: return ["reason", "scope"]
        case .translationStarted: return ["targetLanguage", "automatic", "resumed"]
        case .translationConsent: return ["result"]
        case .translationFinished: return ["outcome", "stage", "reason", "targetLanguage"]
        case .bookmarkAdded: return ["hasNote", "category"]
        case .bookmarkOpened: return ["from"]
        case .transcriptOpened: return ["presentation", "outcome"]
        case .transcriptAction: return ["action"]
        case .settingChanged: return ["setting"]
        case .librarySearched: return ["results"]
        case .libraryFilterSelected: return ["filter"]
        case .supportPrompt: return ["action"]
        case .carPlayConnected: return ["layout"]
        case .watchCommand: return ["command"]
        case .watchTransfer: return ["outcome"]
        case .watchOfflineListening: return ["finished"]
        }
    }

    /// The event's value is seconds, summed into `<name>.minutes` in the summary.
    var valueIsSeconds: Bool {
        self == .translationFinished || self == .watchOfflineListening
    }
}

enum PlaybackKind: Equatable, Sendable {
    case original
    case translation(source: String, target: String)

    var name: String {
        if case .translation = self { return "translation" }
        return "original"
    }

    var sourceLanguage: String? {
        if case let .translation(source, _) = self { return source }
        return nil
    }

    var targetLanguage: String? {
        if case let .translation(_, target) = self { return target }
        return nil
    }

    var parameters: [String: String] {
        switch self {
        case .original:
            return ["kind": "original"]
        case let .translation(source, target):
            return ["kind": "translation", "sourceLanguage": source, "targetLanguage": target]
        }
    }
}

/// Why a talk began playing, set by the public player entry points.
enum PlaybackStartReason: String, Sendable {
    case user
    case autoAdvance
    case next
    case previous
    case queueItem
    case restored
    case bookmark
    case recovered
    /// A long listen sent in parts, or resumed after the app went to the background.
    case continued
}

enum ListeningAction: Sendable {
    case skipForward, skipBack, seek
}

enum ListeningEndTrigger: String, Sendable {
    case finished
    case skippedToEnd
    case switched
    case stopped
    case background
    case periodic
}

enum DownloadOrigin: String, Sendable {
    case user
    case downloadAll
    case smartDownload
    case unknown
}

enum TelemetryParameters {
    /// Series, discourse and language for a catalog discourse ID. Series IDs
    /// can contain hyphens, so the catalog is the source of truth.
    static func discourse(_ discourseID: String) -> [String: String] {
        guard let entry = Catalog.discourseLookup[discourseID] else {
            return ["discourseID": discourseID]
        }
        return [
            "discourseID": discourseID,
            "seriesID": entry.series.id,
            "seriesName": entry.series.name,
            "language": entry.series.language.rawValue,
        ]
    }

    static func series(_ series: SeriesInfo) -> [String: String] {
        ["seriesID": series.id, "seriesName": series.name, "language": series.language.rawValue]
    }

    /// Coarse count buckets keep values comparable across listeners.
    static func bucket(_ count: Int) -> String {
        switch count {
        case ..<1: return "0"
        case 1: return "1"
        case 2...5: return "2-5"
        case 6...10: return "6-10"
        case 11...25: return "11-25"
        case 26...50: return "26-50"
        case 51...100: return "51-100"
        default: return "100+"
        }
    }

    /// Counts in the summary: exact up to 99, so totals can be added up.
    static func count(_ count: Int) -> String {
        count >= 100 ? "100+" : String(max(count, 0))
    }

    static func minutesBucket(_ seconds: Double) -> String {
        switch seconds / 60 {
        case ..<1: return "<1"
        case ..<5: return "1-5"
        case ..<15: return "5-15"
        case ..<30: return "15-30"
        case ..<60: return "30-60"
        default: return "60+"
        }
    }

    static func rate(_ rate: Double) -> String {
        String(format: "%.2f", (rate * 20).rounded() / 20)
    }

    static func flag(_ value: Bool) -> String { value ? "true" : "false" }

    @MainActor
    static var deviceFamily: String {
        #if targetEnvironment(macCatalyst)
        return "mac"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }

    /// The listener's settings, added to every signal.
    @MainActor
    static func settingsContext(_ settings: UserSettings) -> [String: String] {
        [
            "deviceFamily": deviceFamily,
            "Settings.noiseReduction": flag(settings.noiseReduction),
            "Settings.noiseReductionMode": settings.noiseReductionMode.rawValue,
            "Settings.denoiseStrength": settings.denoiseStrength,
            "Settings.voiceFocusPreset": settings.voiceFocusPreset.rawValue,
            "Settings.volumeBoost": String(format: "%.1f", settings.volumeBoost),
            "Settings.smartDownload": flag(settings.smartDownload),
            "Settings.smartDelete": flag(settings.smartDelete),
            "Settings.autoPlayNext": flag(settings.autoPlayNext),
            "Settings.allowCellularDownloads": flag(settings.allowCellularDownloads),
            "Settings.appearance": settings.appearance.rawValue,
            "Settings.accentTheme": settings.accentTheme.rawValue,
            "Settings.dailyAccentShuffle": flag(settings.dailyAccentShuffle),
            "Settings.languageFilter": settings.languageFilter.rawValue,
            "Settings.defaultPlaybackRate": rate(settings.defaultPlaybackRate),
            "Settings.transcriptSentenceLayout": flag(settings.transcriptSentenceLayout),
            "Settings.transcriptFontSize": String(Int(settings.transcriptFontSize)),
            "Settings.transcriptSpeechSync": flag(settings.transcriptSpeechSync),
        ]
    }
}
