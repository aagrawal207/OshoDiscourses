import XCTest

/// Regular-width navigation, player and keyboard checks on iPad, plus the
/// phone tab bar they must leave alone.
final class AdaptiveLayoutTests: XCTestCase {
    private let transcribed = "english-A_Bird_on_the_Wing__-1"

    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: - iPad

    @MainActor
    func testSidebarNavigatesBetweenDestinationsInLandscape() throws {
        try requirePad()
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launch(["-debugPlayerDiscourse", transcribed, "-debugMiniPlayer", "1"])
        defer { app.terminate() }

        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 20))
        XCTAssertTrue(sidebarItem("Library", in: app).exists)
        XCTAssertTrue(sidebarItem("Bookmarks", in: app).exists)
        let mini = app.control("player.mini")
        XCTAssertTrue(mini.waitForExistence(timeout: 10))
        // The mini player sits over content, never over the sidebar.
        XCTAssertGreaterThan(mini.frame.minX, sidebarItem("Library", in: app).frame.maxX)
        capture(app, name: "iPad landscape Home")

        sidebarItem("Library", in: app).tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 10))
        capture(app, name: "iPad landscape Library")

        // Scoped to the grid: the mini player also names the playing series.
        let series = app.scrollViews.buttons.containing(.staticText, identifier: "A Bird on the Wing").firstMatch
        XCTAssertTrue(series.waitForExistence(timeout: 10))
        series.tap()
        XCTAssertTrue(app.staticTexts["Discourse 1"].waitForExistence(timeout: 10))
        capture(app, name: "iPad landscape Series")

        sidebarItem("Downloads", in: app).tap()
        XCTAssertTrue(app.navigationBars["Downloads"].waitForExistence(timeout: 10))
        capture(app, name: "iPad landscape Downloads")

        sidebarItem("Bookmarks", in: app).tap()
        XCTAssertTrue(app.navigationBars["Bookmarks"].waitForExistence(timeout: 10))

        sidebarItem("Settings", in: app).tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        capture(app, name: "iPad landscape Settings")
    }

    @MainActor
    func testPlayerShowsTranscriptBesideControlsInLandscape() throws {
        try requirePad()
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launch(["-debugPlayerDiscourse", transcribed])
        defer { app.terminate() }

        let play = app.buttons["player.playPause"]
        XCTAssertTrue(app.buttons["player.close"].waitForExistence(timeout: 20))
        let pane = showPane(in: app)
        XCTAssertTrue(play.exists)
        XCTAssertGreaterThan(pane.frame.minX, play.frame.maxX)
        XCTAssertGreaterThan(pane.frame.width, app.frame.width * 0.45)
        XCTAssertTrue(app.buttons["Search transcript"].exists)
        capture(app, name: "iPad landscape Player")

        // The Transcript control hides and restores the pane.
        app.buttons["player.transcript"].tap()
        XCTAssertTrue(pane.waitForNonExistence(timeout: 10))
        capture(app, name: "iPad landscape Player without transcript")
        app.buttons["player.transcript"].tap()
        XCTAssertTrue(pane.waitForExistence(timeout: 10))

        app.buttons["player.close"].tap()
        XCTAssertTrue(app.control("player.mini").waitForExistence(timeout: 10))
    }

    @MainActor
    func testPlayerStacksTranscriptBelowControlsInPortrait() throws {
        try requirePad()
        XCUIDevice.shared.orientation = .portrait
        let app = launch(["-debugPlayerDiscourse", transcribed])
        defer { app.terminate() }

        XCTAssertTrue(app.buttons["player.close"].waitForExistence(timeout: 20))
        let pane = showPane(in: app)
        capture(app, name: "iPad portrait Player")
        XCTAssertGreaterThan(pane.frame.minY, app.buttons["player.transcript"].frame.maxY)
        XCTAssertGreaterThan(pane.frame.height, app.frame.height * 0.35)
    }

    @MainActor
    func testKeyboardShortcutsControlPlaybackAndNavigation() throws {
        try requirePad()
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launch(["-debugPlaySample", transcribed])
        defer { app.terminate() }

        let mini = app.control("player.mini")
        XCTAssertTrue(mini.waitForExistence(timeout: 20))
        XCTAssertTrue(waitForValue(mini, "Playing"))

        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(waitForValue(mini, "Paused"))
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(waitForValue(mini, "Playing"))

        app.typeKey("p", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.buttons["player.close"].waitForExistence(timeout: 10))
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(waitForValue(mini, "Paused"))
        // The simulator does not deliver a synthesized Escape to the app, so
        // this drives the same handler through its ⌘. binding.
        app.typeKey(".", modifierFlags: .command)
        XCTAssertTrue(app.buttons["player.close"].waitForNonExistence(timeout: 10))
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(waitForValue(mini, "Playing"))

        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 10))

        // Space typed into search is text, not a playback toggle.
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("tao te")
        XCTAssertEqual(search.value as? String, "tao te")
        // The accessory can hide while search owns the keyboard; Home shows it again.
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitForValue(mini, "Playing"), "Mini player exists: \(mini.exists), value: \(String(describing: mini.value))")

        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testLargeTextLandscapeKeepsSidebarAndPlayerUsable() throws {
        try requirePad()
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launch([
            "-debugPlayerDiscourse", transcribed,
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL",
            "-settings.appearance", "dark",
        ])
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["player.close"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["player.transcript"].exists)
        capture(app, name: "iPad landscape Player accessibility XL dark")
        app.buttons["player.close"].tap()
        XCTAssertTrue(sidebarItem("Library", in: app).waitForExistence(timeout: 10))
        sidebarItem("Library", in: app).tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 10))
        capture(app, name: "iPad landscape Library accessibility XL dark")
    }

    /// Needs downloads seeded into the simulator (see docs/ipad-and-mac.md);
    /// skips otherwise, since the populated screens are what it records.
    @MainActor
    func testPopulatedHomeDownloadsAndSeriesInLandscape() throws {
        try requirePad()
        XCUIDevice.shared.orientation = .landscapeLeft
        let bird = "english-A_Bird_on_the_Wing__-2"
        let geeta = "hindi-Maha_Geeta-5"
        let app = launch([
            "-recentlyPlayed", "(\"\(bird)\", \"\(geeta)\")",
            "-playbackPosition_\(bird)", "1260", "-playbackDuration_\(bird)", "4200",
            "-playbackPosition_\(geeta)", "640", "-playbackDuration_\(geeta)", "5400",
            "-listenedCompletedIDs", "(\"english-A_Bird_on_the_Wing__-1\")",
        ])
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 20))
        guard app.staticTexts["Continue Listening"].waitForExistence(timeout: 5) else {
            throw XCTSkip("No seeded downloads in this simulator")
        }
        XCTAssertTrue(app.staticTexts["Recently Completed"].exists)
        // Side by side on a wide window.
        XCTAssertEqual(app.staticTexts["Continue Listening"].frame.minY, app.staticTexts["Recently Completed"].frame.minY, accuracy: 4)
        capture(app, name: "iPad landscape Home populated")

        sidebarItem("Downloads", in: app).tap()
        XCTAssertTrue(app.navigationBars["Downloads"].waitForExistence(timeout: 10))
        capture(app, name: "iPad landscape Downloads populated")

        let row = app.buttons["Discourse 3"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Remove Download"].waitForExistence(timeout: 5))
        capture(app, name: "iPad landscape Downloads context menu")
    }

    // MARK: - iPhone

    @MainActor
    func testPhoneKeepsBottomTabBarAndSheetPlayer() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("Phone layout check") }
        let app = launch(["-debugPlayerDiscourse", transcribed, "-debugMiniPlayer", "1"])
        defer { app.terminate() }

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 20))
        capture(app, name: "iPhone Home")
        let tree = XCTAttachment(string: tabBar.debugDescription)
        tree.name = "iPhone tab bar"
        tree.lifetime = .keepAlways
        add(tree)
        for title in ["Home", "Library", "Downloads", "Settings"] {
            XCTAssertTrue(tabBar.buttons[title].exists, title)
        }
        XCTAssertFalse(tabBar.buttons["Bookmarks"].exists)
        XCTAssertGreaterThan(tabBar.frame.minY, app.frame.height * 0.8)
        let mini = app.control("player.mini")
        XCTAssertTrue(mini.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(mini.frame.maxY, tabBar.frame.minY + 1)

        mini.tap()
        XCTAssertTrue(app.buttons["player.transcript"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["player.close"].exists)
        XCTAssertFalse(app.control("player.transcriptPane").exists)
        capture(app, name: "iPhone Player")
    }

    // MARK: - Helpers

    /// The pane's visibility persists between launches, so earlier runs may have hidden it.
    @MainActor
    private func showPane(in app: XCUIApplication) -> XCUIElement {
        let pane = app.control("player.transcriptPane")
        if !pane.waitForExistence(timeout: 3) { app.buttons["player.transcript"].tap() }
        XCTAssertTrue(pane.waitForExistence(timeout: 10))
        return pane
    }

    private func requirePad() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad layout check") }
    }

    @MainActor
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        // Smart Download and Smart Delete would fetch or remove real files
        // when the short sample recording ends.
        app.launchArguments = arguments + [
            "-settings.dailyAccentShuffle", "0",
            "-settings.accentTheme", "purple",
            "-settings.smartDownload", "0",
            "-settings.smartDelete", "0",
        ] + (arguments.contains("-settings.appearance") ? [] : ["-settings.appearance", "light"])
        app.launch()
        return app
    }

    @MainActor
    private func sidebarItem(_ title: String, in app: XCUIApplication) -> XCUIElement {
        let cell = app.cells.containing(.staticText, identifier: title).firstMatch
        if cell.exists { return cell }
        let button = app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
        return button
    }

    @MainActor
    private func waitForValue(_ element: XCUIElement, _ value: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout) == .completed
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

private extension XCUIApplication {
    func control(_ identifier: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
