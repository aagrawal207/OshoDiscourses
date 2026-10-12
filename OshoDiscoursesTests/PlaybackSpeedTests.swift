import Foundation
import Testing
@testable import OshoDiscourses

struct PlaybackSpeedTests {
    @Test(arguments: [
        (0.85, 0.85), (0.87, 0.85), (0.88, 0.9), (1.12, 1.1), (1.0000001, 1),
        (0.1, 0.5), (3, 2), (.nan, 1), (.infinity, 1),
    ] as [(Float, Float)])
    func ratesLandOnTheFiveHundredthsGrid(input: Float, expected: Float) {
        #expect(PlaybackSpeed.normalized(input) == expected)
    }

    @Test func everyStepIsExactlyItsLiteral() {
        // The grid must equal literals such as 0.85 so presets and saved speeds compare exactly.
        let literals: [Float] = [0.5, 0.55, 0.6, 0.65, 0.7, 0.75, 0.8, 0.85, 0.9, 0.95, 1, 1.05, 1.1, 1.15, 1.2, 1.25,
                                 1.3, 1.35, 1.4, 1.45, 1.5, 1.55, 1.6, 1.65, 1.7, 1.75, 1.8, 1.85, 1.9, 1.95, 2]
        var rate = PlaybackSpeed.range.lowerBound
        for literal in literals {
            #expect(rate == literal)
            rate = PlaybackSpeed.stepped(rate, by: 1)
        }
        #expect(rate == 2)
        #expect(PlaybackSpeed.stepped(0.5, by: -1) == 0.5)
        #expect(PlaybackSpeed.stepped(1, by: -3) == 0.85)
    }

    @Test(arguments: [
        (1, "1×"), (0.85, "0.85×"), (0.9, "0.9×"), (1.25, "1.25×"), (1.75, "1.75×"), (2, "2×"), (0.5, "0.5×"),
    ] as [(Float, String)])
    func labelsShowEveryMeaningfulDigit(rate: Float, label: String) {
        #expect(PlaybackSpeed.label(rate) == label)
    }

    @Test func spokenLabelAvoidsTheMultiplicationSign() {
        #expect(PlaybackSpeed.accessibilityLabel(0.85) == "0.85 times")
    }

    @MainActor
    @Test func playerRoundsAndPersistsGranularSpeeds() {
        let settings = UserSettings.shared
        let original = settings.defaultPlaybackRate
        defer { settings.defaultPlaybackRate = original }
        let player = AudioPlayerService(settings: settings, connectsToSystem: false)
        player.setRate(0.86)
        #expect(player.playbackRate == 0.85)
        #expect(settings.defaultPlaybackRate == Double(Float(0.85)))
        #expect(AudioPlayerService(settings: settings, connectsToSystem: false).playbackRate == 0.85)
        settings.defaultPlaybackRate = 7
        #expect(AudioPlayerService(settings: settings, connectsToSystem: false).playbackRate == 2)
    }
}
