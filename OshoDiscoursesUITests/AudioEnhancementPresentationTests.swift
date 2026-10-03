import XCTest

final class AudioEnhancementPresentationTests: XCTestCase {
    @MainActor
    func testPlayerCombinesNoiseReductionAndBoostWithoutStartingPlayback() {
        let app = launchPlayer(enhancementEnabled: false)
        defer { app.terminate() }
        let audio = app.buttons["player.audioEnhancement"]
        let transcript = app.buttons["player.transcript"]
        XCTAssertEqual(audio.label, "DeNoise")
        XCTAssertEqual(app.buttons.matching(identifier: "player.transcript").count, 1)
        XCTAssertTrue(transcript.isHittable)
        XCTAssertGreaterThan(transcript.frame.midX, audio.frame.midX)
        XCTAssertEqual(transcript.frame.midY, audio.frame.midY, accuracy: 1)
        capture(app, name: "Player with DeNoise and Transcript together")
        if app.isPad {
            // The full-window player reads along in a pane that this control toggles.
            let pane = app.control("player.transcriptPane")
            let wasShown = pane.exists
            transcript.tap()
            XCTAssertTrue(wasShown ? pane.waitForNonExistence(timeout: 10) : pane.waitForExistence(timeout: 10))
            transcript.tap()
            XCTAssertEqual(pane.waitForExistence(timeout: wasShown ? 10 : 2), wasShown)
        } else {
            transcript.tap()
            XCTAssertTrue(app.buttons["Search transcript"].waitForExistence(timeout: 10))
            app.buttons["Close"].tap()
        }
        XCTAssertTrue(audio.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Volume boost"].exists)
        audio.tap()
        XCTAssertTrue(app.buttons["audioEnhancement.done"].waitForExistence(timeout: 10))

        let toggle = app.switches["audioEnhancement.enabled"]
        let boost = app.control("audioEnhancement.boost")
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertFalse(boost.isEnabled)
        XCTAssertTrue(app.control("audioEnhancement.mode").valueDescription.contains("Best Quality"))
        XCTAssertTrue(app.staticTexts["audioEnhancement.boostExplanation"].label.contains("Turn on DeNoise"))

        capture(app, name: "Audio enhancement — original sound")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertTrue(app.staticTexts["Ready for playback"].exists)
        reveal(boost, in: app)
        XCTAssertTrue(boost.isEnabled)
        boost.buttons["High"].tap()
        XCTAssertEqual(boost.value as? String, "High")
        XCTAssertTrue(app.staticTexts["audioEnhancement.boostExplanation"].label.contains("will apply"))
        capture(app, name: "Audio enhancement — enabled, boost saved for playback")

        app.buttons["audioEnhancement.done"].tap()
        XCTAssertTrue(audio.waitForExistence(timeout: 10))
        audio.tap()
        XCTAssertTrue(app.buttons["audioEnhancement.done"].waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "1")
        reveal(boost, in: app)
        XCTAssertEqual(boost.value as? String, "High")
        reveal(toggle, in: app, swipeUp: false)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertFalse(boost.isEnabled)
        XCTAssertEqual(boost.value as? String, "High")
        capture(app, name: "Audio enhancement — off, boost dependency explained")
    }

    @MainActor
    func testSettingsOffersRecommendedAndSecondaryModesAndRemembersTheChoice() {
        let app = launchPlayer(enhancementEnabled: true)
        defer { app.terminate() }
        if app.isPad {
            app.buttons["player.close"].tap()
        } else {
            let playerContent = app.scrollViews.containing(.button, identifier: "player.audioEnhancement").firstMatch
            playerContent.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        }
        XCTAssertTrue(app.buttons["player.audioEnhancement"].waitForNonExistence(timeout: 10))
        openFromSettings(app)

        let mode = app.control("audioEnhancement.mode")
        for _ in 0..<3 { scroll(app, up: true) }
        let footer = app.staticTexts["audioEnhancement.footer"]
        let miniPlayer = app.control("player.mini")
        XCTAssertTrue(footer.exists)
        XCTAssertTrue(miniPlayer.exists)
        XCTAssertLessThanOrEqual(footer.frame.maxY + 8, miniPlayer.frame.minY)
        XCTAssertTrue(app.control("audioEnhancement.fineTune").isHittable)
        capture(app, name: "DeNoise footer above the mini-player")
        reveal(mode, in: app, swipeUp: false)
        mode.tap()
        XCTAssertTrue(app.navigationBars["Listening Mode"].waitForExistence(timeout: 10))
        let quality = app.buttons["audioEnhancement.mode.deepFilterNet"]
        let balanced = app.buttons["audioEnhancement.mode.rnnoise"]
        let gentle = app.buttons["audioEnhancement.mode.cadence"]
        XCTAssertTrue(quality.isSelected)
        XCTAssertLessThan(quality.frame.minY, balanced.frame.minY)
        XCTAssertLessThan(balanced.frame.minY, gentle.frame.minY)
        XCTAssertTrue(app.staticTexts["Uses more battery"].exists)
        capture(app, name: "Listening modes — recommended quality and lighter options")

        balanced.tap()
        XCTAssertTrue(app.navigationBars["DeNoise"].waitForExistence(timeout: 10))
        XCTAssertTrue(mode.valueDescription.contains("Balanced"))
        XCTAssertEqual(app.switches["audioEnhancement.enabled"].value as? String, "1")
        XCTAssertFalse(app.staticTexts["Fine-tune the voice"].exists)
        XCTAssertTrue(app.control("audioEnhancement.boost").isEnabled)

        mode.tap()
        XCTAssertTrue(app.navigationBars["Listening Mode"].waitForExistence(timeout: 10))
        // The push must settle first; iPad's taller list otherwise takes the tap mid-transition.
        XCTAssertTrue(gentle.waitForExistence(timeout: 10))
        reveal(gentle, in: app)
        gentle.tap()
        XCTAssertTrue(mode.waitForExistence(timeout: 10))
        XCTAssertTrue(mode.valueDescription.contains("Gentle Cleanup"))

        app.terminate()
        app.launchArguments = []
        app.launch()
        openFromSettings(app)
        XCTAssertTrue(mode.valueDescription.contains("Gentle Cleanup"))
        XCTAssertEqual(app.switches["audioEnhancement.enabled"].value as? String, "1")
    }

    @MainActor
    func testLargeTextDarkAppearanceKeepsControlsReachable() {
        let app = launchPlayer(enhancementEnabled: true, largeText: true)
        defer { app.terminate() }
        capture(app, name: "Player controls with large text")
        app.buttons["player.audioEnhancement"].tap()
        XCTAssertTrue(app.buttons["audioEnhancement.done"].waitForExistence(timeout: 10))
        capture(app, name: "Audio enhancement — large text, dark appearance")

        let strength = app.control("audioEnhancement.strength")
        reveal(strength, in: app)
        strength.tap()
        app.buttons["Light"].tap()

        let boost = app.control("audioEnhancement.boost")
        reveal(boost, in: app)
        XCTAssertGreaterThanOrEqual(boost.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(boost.frame.maxX, app.frame.maxX)
        boost.tap()
        app.buttons["Low"].tap()
        XCTAssertEqual(boost.value as? String, "Low")
        capture(app, name: "Audio enhancement — large text boost control")

        let fineTune = app.control("audioEnhancement.fineTune")
        reveal(fineTune, in: app)
        fineTune.tap()
        XCTAssertTrue(app.navigationBars["Quiet Speech"].waitForExistence(timeout: 10))
        let voice = app.buttons["audioEnhancement.voice.lift"]
        reveal(voice, in: app)
        voice.tap()
        XCTAssertTrue(fineTune.waitForExistence(timeout: 10))
        XCTAssertTrue(fineTune.valueDescription.contains("Gentle Lift"))
        app.buttons["audioEnhancement.done"].tap()
        XCTAssertTrue(app.buttons["player.audioEnhancement"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func launchPlayer(enhancementEnabled: Bool, largeText: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-debugPlayerDiscourse", "hindi-Maha_Geeta-5"]
            + preferenceArguments(enabled: enhancementEnabled, largeText: largeText)
        app.launch()
        XCTAssertTrue(app.buttons["player.audioEnhancement"].waitForExistence(timeout: 20))
        reveal(app.buttons["player.audioEnhancement"], in: app)
        return app
    }

    private func preferenceArguments(enabled: Bool, largeText: Bool = false) -> [String] {
        var arguments = [
            "-settings.noiseReduction", enabled ? "1" : "0",
            "-settings.noiseReductionMode", "deepFilterNet",
            "-settings.denoiseStrength", "medium",
            "-settings.voiceFocusPreset", "focus",
            "-settings.volumeBoost", "2",
            "-settings.appearance", largeText ? "dark" : "light",
            "-settings.dailyAccentShuffle", "0",
            "-settings.accentTheme", "purple",
        ]
        if largeText {
            arguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]
        }
        return arguments
    }

    @MainActor
    private func openFromSettings(_ app: XCUIApplication) {
        app.openDestination("Settings")
        let entry = app.control("settings.audioEnhancement")
        reveal(entry, in: app)
        entry.tap()
        XCTAssertTrue(app.navigationBars["DeNoise"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, swipeUp: Bool = true) {
        for _ in 0..<8 {
            if element.exists, element.isHittable,
               element.frame.minY >= app.frame.minY + 110,
               element.frame.maxY <= app.frame.maxY - 8 { return }
            if element.exists, element.frame.minY < app.frame.minY + 110 {
                scroll(app, up: false)
            } else if swipeUp {
                scroll(app, up: true)
            } else {
                scroll(app, up: false)
            }
        }
        capture(app, name: "Unreachable control")
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        XCTFail("Control is not reachable: \(element)")
    }

    @MainActor
    private func scroll(_ app: XCUIApplication, up: Bool) {
        let surface = app.collectionViews.allElementsBoundByIndex.last(where: { $0.isHittable })
            ?? app.scrollViews.allElementsBoundByIndex.last(where: { $0.isHittable })
            ?? app
        // Starts above the mini player, which floats over the lower fifth of a small phone.
        let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: up ? 0.7 : 0.3))
        let end = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: up ? 0.25 : 0.7))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

private extension XCUIElement {
    var valueDescription: String { value as? String ?? "" }
}

private extension XCUIApplication {
    func control(_ identifier: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
