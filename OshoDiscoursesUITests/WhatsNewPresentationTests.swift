import XCTest

final class WhatsNewPresentationTests: XCTestCase {
    @MainActor
    func testUpdateAnnouncesTheNewReleaseWhatWasSkippedAndTheHistory() {
        continueAfterFailure = false
        let app = XCUIApplication()
        // The argument domain makes this launch look like an update from 1.16.2.
        app.launchArguments = ["-debugWhatsNew", "-whatsNew.lastSeenVersion", "1.16.2"]
        app.launch()
        defer { app.terminate() }

        let continueButton = app.buttons["whatsNew.continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 15))
        XCTAssertTrue(app.navigationBars["What's New"].exists)
        XCTAssertTrue(app.staticTexts["Listen in Hindi or English"].exists)
        XCTAssertTrue(app.staticTexts["At Osho's pace"].exists)
        capture(app, name: "What's New after an update")

        let list = app.descendants(matching: .any)["whatsNew.list"]
        let skipped = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "since your last update")).firstMatch
        for _ in 0..<6 where !skipped.exists { list.swipeUp() }
        XCTAssertTrue(skipped.exists)
        let earlier = app.buttons["whatsNew.earlier"]
        for _ in 0..<4 where !earlier.isHittable { list.swipeUp() }
        earlier.tap()
        XCTAssertTrue(app.navigationBars["Earlier Updates"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["The first release of Osho Talks."].exists || app.cells.count > 3)
        capture(app, name: "Earlier updates")
        app.navigationBars["Earlier Updates"].buttons.element(boundBy: 0).tap()

        continueButton.tap()
        XCTAssertTrue(continueButton.waitForNonExistence(timeout: 5))
        app.openDestination("Settings")
        let row = app.buttons["settings.whatsNew"]
        for _ in 0..<8 where !row.exists || !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.exists)
        row.tap()
        XCTAssertTrue(app.staticTexts["Listen in Hindi or English"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["whatsNew.continue"].exists)
    }

    @MainActor
    func testFreshInstallDoesNotAnnounce() {
        continueAfterFailure = false
        let app = XCUIApplication()
        // A seen version equal to the installed one is what a fresh install records.
        app.launchArguments = ["-debugWhatsNew", "-whatsNew.lastSeenVersion", "99.0"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["whatsNew.continue"].waitForExistence(timeout: 3))
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
