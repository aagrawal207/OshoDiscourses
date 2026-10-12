import XCTest

final class PlaybackSpeedControlTests: XCTestCase {
    @MainActor
    func testSpeedStepsPresetsAndSliderReachGranularSpeeds() {
        continueAfterFailure = false
        let app = launchPlayer()
        defer { app.terminate() }
        let speed = app.buttons["player.speed"]
        XCTAssertEqual(speed.value as? String, "1 times")
        speed.tap()

        let slower = app.buttons["player.speed.slower"]
        XCTAssertTrue(slower.waitForExistence(timeout: 5))
        for _ in 0..<3 { slower.tap() }
        XCTAssertEqual(app.sliders["player.speedSlider"].value as? String, "0.85 times")
        capture(app, name: "Speed control at 0.85x")

        app.buttons["player.speed.faster"].tap()
        XCTAssertEqual(app.sliders["player.speedSlider"].value as? String, "0.9 times")

        app.buttons["player.speed.preset.1.5×"].tap()
        XCTAssertEqual(app.sliders["player.speedSlider"].value as? String, "1.5 times")

        app.sliders["player.speedSlider"].adjust(toNormalizedSliderPosition: 0)
        XCTAssertEqual(app.sliders["player.speedSlider"].value as? String, "0.5 times")
        XCTAssertFalse(slower.isEnabled)

        // The chosen speed survives closing the control and relaunching.
        app.otherElements["PopoverDismissRegion"].firstMatch.tap()
        XCTAssertTrue(slower.waitForNonExistence(timeout: 5))
        XCTAssertEqual(speed.value as? String, "0.5 times")
        app.terminate()
        let relaunched = launchPlayer(resetSpeed: false)
        XCTAssertEqual(relaunched.buttons["player.speed"].value as? String, "0.5 times")
        relaunched.terminate()
    }

    @MainActor
    func testSpeedControlFitsAtLargestText() {
        continueAfterFailure = false
        let app = launchPlayer(extraArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        defer { app.terminate() }
        app.buttons["player.speed"].tap()
        let faster = app.buttons["player.speed.faster"]
        XCTAssertTrue(faster.waitForExistence(timeout: 5))
        capture(app, name: "Speed control opened at largest text")
        for identifier in ["player.speed.slower", "player.speed.faster", "player.speed.preset.0.75×", "player.speed.preset.2×"] {
            let control = app.buttons[identifier]
            XCTAssertTrue(control.isHittable, identifier)
            XCTAssertGreaterThanOrEqual(control.frame.minX, app.frame.minX, identifier)
            XCTAssertLessThanOrEqual(control.frame.maxX, app.frame.maxX, identifier)
        }
        faster.tap()
        XCTAssertEqual(app.sliders["player.speedSlider"].value as? String, "1.05 times")
        capture(app, name: "Speed control at largest text")
    }

    @MainActor
    private func launchPlayer(resetSpeed: Bool = true, extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-debugPlayerDiscourse", "english-A_Bird_on_the_Wing__-1"] + extraArguments
        // The argument domain masks earlier runs' saved speed for this launch only.
        if resetSpeed { app.launchArguments += ["-settings.defaultPlaybackRate", "1"] }
        app.launch()
        XCTAssertTrue(app.buttons["player.speed"].waitForExistence(timeout: 20))
        return app
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
