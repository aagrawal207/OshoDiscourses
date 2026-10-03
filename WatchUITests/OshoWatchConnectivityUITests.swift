import XCTest

/// Real WatchConnectivity against the paired iPhone simulator; skipped unless
/// OSHO_WATCH_INTEGRATION=1. The phone must already run Osho Talks with A Bird
/// on the Wing #1–#3 downloaded and #1 loaded (see docs/apple-watch.md).
/// File delivery itself needs a physical Watch.
@MainActor
final class OshoWatchConnectivityUITests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OSHO_WATCH_INTEGRATION"] == "1",
                          "Paired-simulator test; set TEST_RUNNER_OSHO_WATCH_INTEGRATION=1")
        continueAfterFailure = false
    }

    private func waitFor(_ format: String, _ value: String, on element: XCUIElement, timeout: TimeInterval,
                         file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
                       "\(element) never matched \(format) \(value)", file: file, line: line)
    }

    /// Covers the Watch's 8 s deadline, an "outcome unknown" refresh and its reply.
    static let replyTimeout: TimeInterval = 30

    private func waitUntilEnabled(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: Self.replyTimeout), .completed,
                       "\(element.identifier) never enabled", file: file, line: line)
    }

    func testPairedPhoneControlsBrowsingAndSaveToWatch() {
        let app = XCUIApplication()
        app.launch()

        let remote = app.buttons["watch.home.remote"]
        XCTAssertTrue(remote.waitForExistence(timeout: 30), app.debugDescription)
        waitFor("label CONTAINS %@", "A Bird on the Wing", on: remote, timeout: 30)
        remote.tap()

        // Pause and resume. Labels change only on confirmed replies, and simulator
        // WatchConnectivity can take seconds per message.
        let toggle = app.buttons["watch.player.playPause"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        for _ in 0..<2 {
            waitUntilEnabled(toggle)
            let before = toggle.label
            toggle.tap()
            waitFor("label != %@", before, on: toggle, timeout: Self.replyTimeout)
        }

        // Relaunch to return to the root list; the phone state survives.
        app.terminate()
        app.launch()

        let downloads = app.buttons["watch.home.Downloads"]
        XCTAssertTrue(downloads.waitForExistence(timeout: 10), app.debugDescription)
        downloads.tap()
        let series = app.buttons["watch.row.s:english-A_Bird_on_the_Wing__"]
        XCTAssertTrue(series.waitForExistence(timeout: Self.replyTimeout), app.debugDescription)
        series.tap()

        let third = app.buttons["watch.row.d:english-A_Bird_on_the_Wing__-3"]
        XCTAssertTrue(third.waitForExistence(timeout: Self.replyTimeout), app.debugDescription)
        third.swipeLeft()
        let save = app.buttons["Save to Watch"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        // The phone accepted and queued the transfer. Simulator WatchConnectivity
        // reports file transfers finished without delivering them to the Watch app.
        waitFor("label CONTAINS %@", "Sending from iPhone", on: third, timeout: Self.replyTimeout)

        // Rows stay disabled until the phone confirms the Save to Watch request.
        waitUntilEnabled(third)
        third.tap()
        XCTAssertTrue(app.buttons["watch.player.playPause"].waitForExistence(timeout: Self.replyTimeout), app.debugDescription)
        let nowPlaying = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Wing - #3")).firstMatch
        XCTAssertTrue(nowPlaying.waitForExistence(timeout: Self.replyTimeout), app.debugDescription)
    }
}
