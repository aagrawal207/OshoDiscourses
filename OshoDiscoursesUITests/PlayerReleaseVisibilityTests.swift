import XCTest

// Translated narration is deferred; these keep its entry points out of shipping builds.
final class PlayerReleaseVisibilityTests: XCTestCase {
    @MainActor
    func testPlayerKeepsTranscriptAndDeNoiseWithoutTranslationEntryPoints() {
        continueAfterFailure = false
        let app = XCUIApplication()
        for discourseID in ["english-A_Bird_on_the_Wing__-1", "hindi-Maha_Geeta-5"] {
            app.launchArguments = ["-debugPlayerDiscourse", discourseID]
            app.launch()
            XCTAssertTrue(app.buttons["player.audioEnhancement"].waitForExistence(timeout: 20))
            XCTAssertTrue(app.buttons["player.transcript"].exists)
            XCTAssertTrue(app.buttons["Add bookmark"].exists)
            XCTAssertFalse(app.buttons["player.translate"].exists)
            XCTAssertFalse(app.buttons["Read translated narration"].exists)
            XCTAssertFalse(app.buttons["narration.recoverPlayback"].exists)
            capture(app, name: "Release player without translation")
            app.terminate()
        }
    }

    @MainActor
    func testDownloadsAndDebugShortcutDoNotExposeNarration() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-debugNarration", "hindi-Maha_Geeta-5"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["narration.done"].exists)
        app.openDestination("Downloads")
        XCTAssertTrue(app.navigationBars["Downloads"].waitForExistence(timeout: 10))
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Listening Stats"].exists)
        XCTAssertTrue(app.staticTexts["Bookmarks"].exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "downloads.translatedNarrations").firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Translated Narrations"].exists)
        capture(app, name: "Release Downloads without translated narrations")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
