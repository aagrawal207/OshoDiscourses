import XCTest

#if TRANSLATED_NARRATION
final class NarrationPresentationTests: XCTestCase {
    @MainActor
    func testFirstGlobeTapFromPausedEnglishPlayerShowsNarration() throws {
        try checkGlobePresentation(discourseID: "english-A_Bird_on_the_Wing__-1", title: "A Bird on the Wing - #1")
    }

    @MainActor
    func testFirstGlobeTapFromPausedHindiPlayerShowsNarration() throws {
        try checkGlobePresentation(discourseID: "hindi-Maha_Geeta-5", title: "Ashtavakra Maha Geeta - #5")
    }

    @MainActor
    func testDownloadsOpensAndReopensSavedNarrations() throws {
        try requireTranslationRuntime()
        let app = launch(arguments: ["-settings.appearance", "light"])
        defer { app.terminate() }
        app.openDestination("Downloads")
        for opening in 1...2 {
            XCTAssertTrue(app.navigationBars["Downloads"].waitForExistence(timeout: 10))
            let link = control("downloads.translatedNarrations", in: app)
            reveal(link, in: app)
            link.tap()
            XCTAssertTrue(app.navigationBars["Translated Narrations"].waitForExistence(timeout: 10))
            XCTAssertTrue(control("narration.library", in: app).exists)
            XCTAssertTrue(control("narration.library.loading", in: app).waitForNonExistence(timeout: 20))
            let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "narration.library.")).firstMatch
            XCTAssertTrue(control("narration.library.empty", in: app).exists || saved.exists)
            capture(app, name: "Saved narrations opening \(opening)")
            app.navigationBars["Translated Narrations"].buttons.element(boundBy: 0).tap()
        }
    }

    @MainActor
    func testDiscourseWithoutTranscriptExplainsWhyPreparationIsUnavailable() throws {
        try requireTranslationRuntime()
        let app = launch(arguments: ["-debugNarration", "hindi-Dharam_Aur_Anand-1"])
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["narration.done"].waitForExistence(timeout: 20))
        XCTAssertTrue(control("narration.noTranscript", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Dharam Aur Anand - #1"].exists)
        XCTAssertFalse(app.buttons["narration.prepare"].exists)
        XCTAssertFalse(app.buttons["narration.refreshLanguages"].exists)
        XCTAssertFalse(control("narration.targetLanguage", in: app).exists)
        capture(app, name: "Narration requires a source transcript")
        app.buttons["narration.done"].tap()
        XCTAssertTrue(app.buttons["narration.done"].waitForNonExistence(timeout: 10))
    }

    @MainActor
    func testLanguageAvailabilityCanBeRetriedForBothSources() throws {
        try requireTranslationRuntime()
        for discourseID in ["english-A_Bird_on_the_Wing__-1", "hindi-Maha_Geeta-5"] {
            let app = launch(arguments: ["-debugNarration", discourseID])
            XCTAssertTrue(app.buttons["narration.done"].waitForExistence(timeout: 20))
            waitForLanguageCheck(in: app)
            assertLanguageOutcome(in: app)
            let retry = app.buttons["narration.refreshLanguages"]
            reveal(retry, in: app)
            retry.tap()
            waitForLanguageCheck(in: app)
            assertLanguageOutcome(in: app)
            capture(app, name: "Language availability after retry: \(discourseID)")
            app.terminate()
        }
    }

    @MainActor
    func testLargeTextDarkPresentationKeepsLanguageActionsReachable() throws {
        try requireTranslationRuntime()
        let app = launch(arguments: [
            "-debugPlayerDiscourse", "hindi-Maha_Geeta-5", "-settings.appearance", "dark",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL",
        ])
        defer { app.terminate() }
        let globe = app.buttons["player.translate"]
        XCTAssertTrue(globe.waitForExistence(timeout: 20))
        reveal(globe, in: app)
        globe.tap()
        XCTAssertTrue(app.buttons["narration.done"].waitForExistence(timeout: 10))
        waitForLanguageCheck(in: app)
        let retry = app.buttons["narration.refreshLanguages"]
        reveal(retry, in: app)
        XCTAssertTrue(retry.isHittable)
        retry.tap()
        waitForLanguageCheck(in: app)
        let footer = control("narration.preparationFooter", in: app)
        reveal(footer, in: app)
        XCTAssertGreaterThanOrEqual(footer.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(footer.frame.maxX, app.frame.maxX)
        XCTAssertLessThanOrEqual(footer.frame.maxY, app.frame.maxY - 8)
        XCTAssertTrue(app.buttons["narration.done"].isHittable)
        capture(app, name: "Narration language actions at large text")
        app.buttons["narration.done"].tap()
        XCTAssertTrue(app.buttons["narration.done"].waitForNonExistence(timeout: 10))
    }

    @MainActor
    func testKeyboardDismissesNarrationBeforeTheCoveredPlayer() throws {
        try requireTranslationRuntime()
        let app = launch(arguments: ["-debugPlayerDiscourse", "english-A_Bird_on_the_Wing__-1"])
        defer { app.terminate() }
        guard app.isPad else { throw XCTSkip("Keyboard coverage runs in the regular-width player") }
        XCTAssertTrue(app.buttons["player.close"].waitForExistence(timeout: 20))
        app.buttons["player.translate"].tap()
        XCTAssertTrue(app.buttons["narration.done"].waitForExistence(timeout: 10))
        app.typeKey(".", modifierFlags: .command)
        XCTAssertTrue(app.buttons["narration.done"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.buttons["player.close"].exists, "Dismissing narration must not dismiss its player")
        app.typeKey(".", modifierFlags: .command)
        XCTAssertTrue(app.buttons["player.close"].waitForNonExistence(timeout: 10))
    }

    @MainActor
    func testDownloadsNarrationLinkClearsMiniPlayerAtLargeText() throws {
        try requireTranslationRuntime()
        let app = launch(arguments: [
            "-debugPlayerDiscourse", "english-A_Bird_on_the_Wing__-1", "-debugMiniPlayer", "1",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL",
        ])
        defer { app.terminate() }
        XCTAssertTrue(control("player.mini", in: app).waitForExistence(timeout: 20))
        app.openDestination("Downloads")
        let link = control("downloads.translatedNarrations", in: app)
        reveal(link, in: app)
        app.swipeUp()
        let mini = control("player.mini", in: app)
        XCTAssertTrue(link.isHittable)
        XCTAssertLessThanOrEqual(link.frame.maxY, mini.frame.minY + 1)
        link.tap()
        XCTAssertTrue(app.navigationBars["Translated Narrations"].waitForExistence(timeout: 10))
        XCTAssertTrue(control("narration.library.loading", in: app).waitForNonExistence(timeout: 20))
        capture(app, name: "Saved narrations with mini player")
    }

    @MainActor
    private func checkGlobePresentation(discourseID: String, title: String) throws {
        try requireTranslationRuntime()
        let app = launch(arguments: ["-debugPlayerDiscourse", discourseID, "-settings.appearance", "light"])
        defer { app.terminate() }
        let globe = app.buttons["player.translate"]
        XCTAssertTrue(globe.waitForExistence(timeout: 20))
        for opening in 1...2 {
            reveal(globe, in: app)
            globe.tap()
            let done = app.buttons["narration.done"]
            XCTAssertTrue(done.waitForExistence(timeout: 10), "The first tap must not open an empty sheet")
            XCTAssertTrue(app.navigationBars["Translated Narration"].exists)
            XCTAssertTrue(app.staticTexts[title].exists)
            XCTAssertTrue(control("narration.preparation", in: app).exists)
            XCTAssertTrue(control("narration.explanation", in: app).exists)
            waitForLanguageCheck(in: app)
            assertLanguageOutcome(in: app)
            capture(app, name: "\(title): narration opening \(opening)")
            done.tap()
            XCTAssertTrue(done.waitForNonExistence(timeout: 10))
            XCTAssertTrue(globe.waitForExistence(timeout: 10))
        }
    }

    private func requireTranslationRuntime() throws {
        guard #available(macCatalyst 26.0, *) else { throw XCTSkip("Apple Translation requires Mac Catalyst 26") }
    }

    @MainActor
    private func launch(arguments: [String]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    @MainActor
    private func waitForLanguageCheck(in app: XCUIApplication) {
        let retry = app.buttons["narration.refreshLanguages"]
        reveal(retry, in: app)
        XCTAssertTrue(retry.waitForExistence(timeout: 20))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: retry)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
    }

    @MainActor
    private func assertLanguageOutcome(in app: XCUIApplication) {
        // Simulator language support varies by runtime; neither outcome may silently offer source-language audio.
        XCTAssertTrue(control("narration.targetLanguage", in: app).exists || control("narration.unavailable", in: app).exists)
        if control("narration.unavailable", in: app).exists {
            XCTAssertFalse(app.buttons["narration.prepare"].exists)
        }
    }

    @MainActor
    private func control(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 {
            if element.exists, element.isHittable, app.frame.contains(element.frame), element.frame.maxY <= app.frame.maxY - 8 { return }
            let top = app.navigationBars.allElementsBoundByIndex.last?.frame.maxY ?? app.frame.minY
            let upward = !element.exists || element.frame.maxY > top
            // The lower screen can contain the mini-player, so scroll from the content's middle.
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: upward ? 0.60 : 0.25))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: upward ? 0.25 : 0.60))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        capture(app, name: "Unreachable narration control")
        XCTFail("Control is not reachable: \(element)")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
#endif
