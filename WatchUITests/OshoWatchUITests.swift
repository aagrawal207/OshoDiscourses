import XCTest

/// Fixture-driven checks of the watch UI; no phone or WatchConnectivity is involved.
@MainActor
final class OshoWatchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func waitFor(_ format: String, _ value: String, on element: XCUIElement, timeout: TimeInterval,
                         file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, file: file, line: line)
    }

    private func launch(_ fixture: String, route: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--watch-fixture", fixture] + (route.map { ["--watch-route", $0] } ?? [])
        app.launch()
        return app
    }

    private func assertTarget(_ element: XCUIElement, minimum: CGFloat, in app: XCUIApplication,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(element.isHittable, "\(element.identifier) hittable", file: file, line: line)
        let frame = element.frame
        XCTAssertGreaterThanOrEqual(frame.width + 1e-6, minimum, element.identifier, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.height + 1e-6, minimum, element.identifier, file: file, line: line)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(frame), "\(element.identifier) fully visible",
                      file: file, line: line)
    }

    func testTransportIsFullyVisibleInTheFirstViewport() {
        let app = launch("paused")
        assertTarget(app.buttons["watch.player.playPause"], minimum: 52, in: app)
        assertTarget(app.buttons["watch.player.back"], minimum: 44, in: app)
        assertTarget(app.buttons["watch.player.forward"], minimum: 44, in: app)
        XCTAssertEqual(app.buttons["watch.player.playPause"].label, "Play on iPhone")
    }

    func testPlayPauseFlipsOnlyAfterThePhoneReplies() {
        let app = launch("playing")
        let toggle = app.buttons["watch.player.playPause"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.label, "Pause on iPhone")
        toggle.tap()
        waitFor("label == %@", "Play on iPhone", on: toggle, timeout: 5)
    }

    func testChoosingARowPlaysOnIPhoneAndOpensNowPlaying() {
        let app = launch("empty", route: "home")
        app.buttons["watch.home.Continue Listening"].tap()
        // The empty fixture lists nothing, so the page's own message shows.
        XCTAssertTrue(app.staticTexts["Talks you start on iPhone appear here."].waitForExistence(timeout: 5))

        let playing = launch("paused", route: "continue")
        let row = playing.buttons["watch.row.d:ek-omkar-satnam-4"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let title = playing.staticTexts["Ek Omkar Satnam #4"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(playing.buttons["watch.player.playPause"].label, "Pause on iPhone")
    }

    func testSaveToWatchShowsSendingUntilTheFileArrives() {
        let app = launch("paused", route: "continue")
        let row = app.buttons["watch.row.d:ek-omkar-satnam-4"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.swipeLeft()
        let save = app.buttons["Save to Watch"]
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        save.tap()
        waitFor("label CONTAINS %@", "Sending from iPhone", on: row, timeout: 5)
        // The fixture phone delivers the file after three seconds.
        waitFor("label CONTAINS %@", "On Watch", on: row, timeout: 8)
    }

    func testRemovingASavedTalkUpdatesTheList() {
        let app = launch("offline")
        let row = app.buttons["watch.offline.tao-the-three-treasures-7"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "3 talks")).firstMatch.exists)
        row.swipeLeft()
        app.buttons["Remove"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "2 talks")).firstMatch
            .waitForExistence(timeout: 5))
        XCTAssertFalse(row.exists)
    }

    func testDisconnectedLeadsWithSavedTalksAndExplainsThePhone() {
        let app = launch("disconnected")
        assertTarget(app.buttons["watch.home.offline"], minimum: 44, in: app)
        let remote = app.buttons["watch.home.remote"]
        XCTAssertTrue(remote.waitForExistence(timeout: 5))
        XCTAssertTrue(remote.label.contains("Last seen on iPhone"), remote.label)
        let explanation = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Open Osho Talks on iPhone")).firstMatch
        // Crown steps reveal the explanation below the saved talks and last-seen rows.
        for _ in 0..<6 where !explanation.exists {
            XCUIDevice.shared.rotateDigitalCrown(delta: 0.15)
        }
        XCTAssertTrue(explanation.waitForExistence(timeout: 3), app.debugDescription)
    }
}
