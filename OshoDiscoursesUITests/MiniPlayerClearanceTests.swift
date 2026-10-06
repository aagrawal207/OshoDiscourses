import XCTest

/// With the floating mini-player showing, the last item on each scrolling page must come to rest
/// above it rather than behind it.
final class MiniPlayerClearanceTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testLastItemsScrollClearOfTheMiniPlayer() {
        checkPages(extraArguments: [])
    }

    /// The player grows with Dynamic Type, so a fixed clearance would fall short here.
    @MainActor
    func testLastItemsScrollClearAtLargeText() {
        checkPages(extraArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
    }

    @MainActor
    private func checkPages(extraArguments: [String]) {
        let app = XCUIApplication()
        app.launchArguments = extraArguments + [
            "-debugPlayerDiscourse", "english-A_Bird_on_the_Wing__-1", "-debugMiniPlayer", "1",
            "-settings.appearance", "light", "-settings.smartDownload", "0", "-settings.smartDelete", "0",
        ]
        app.launch()
        defer { app.terminate() }
        let mini = app.control("player.mini")
        XCTAssertTrue(mini.waitForExistence(timeout: 20))
        // A phone shelf scrolls sideways, so its first tile is on the last row; the iPad grid wraps.
        let lastHomeName = app.isPad ? "Jeevan Kranti Ke Sutra" : "Main Mrityu Sikhata Hun"
        let lastHomeTile = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", lastHomeName)).firstMatch
        assertRestsAboveMiniPlayer(lastHomeTile, page: "Home", in: app, mini: mini)

        // Series opens from the top of Library; Home's first shelves are offscreen by now.
        app.openDestination("Library")
        let series = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "A Bird on the Wing")).firstMatch
        XCTAssertTrue(series.waitForExistence(timeout: 10))
        series.tap()
        let lastDiscourse = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Discourse 11")).firstMatch
        assertRestsAboveMiniPlayer(lastDiscourse, page: "Series", in: app, mini: mini)

        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        let lastSeries = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Zen: The Solitary Bird")).firstMatch
        assertRestsAboveMiniPlayer(lastSeries, page: "Library", in: app, mini: mini)

        app.openDestination("Settings")
        let footer = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Your listening progress")).firstMatch
        assertRestsAboveMiniPlayer(footer, page: "Settings", in: app, mini: mini)

        app.openDestination("Downloads")
        let stats = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Listening Stats")).firstMatch
        // At accessibility sizes on smaller screens the row starts below the fold.
        for _ in 0..<8 where !stats.isHittable {
            app.swipeUp()
        }
        stats.tap()
        let history = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Full Listening History")).firstMatch
        assertRestsAboveMiniPlayer(history, page: "Listening Stats", in: app, mini: mini)
    }

    @MainActor
    private func assertRestsAboveMiniPlayer(_ element: XCUIElement, page: String, in app: XCUIApplication,
                                            mini: XCUIElement) {
        // Library holds 351 series, so swipe until the last row renders, then settle at the end.
        var swipes = 0
        while !element.exists, swipes < 80 {
            app.swipeUp(velocity: .fast)
            swipes += 1
        }
        for _ in 0..<3 {
            app.swipeUp(velocity: .fast)
        }
        // Let deceleration and the bounce settle before reading frames.
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(element.waitForExistence(timeout: 5), "\(page): last item not found")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "\(page) scrolled to the bottom"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertLessThanOrEqual(element.frame.maxY, mini.frame.minY + 1,
                                 "\(page): last item ends at \(element.frame.maxY), mini-player starts at \(mini.frame.minY)")
    }
}

private extension XCUIApplication {
    func control(_ identifier: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
