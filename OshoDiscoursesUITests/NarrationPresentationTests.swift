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
    func testDiscourseWithoutTranscriptExplainsWhyPreparationIsUnavailable() throws {
        try requireTranslationRuntime()
        let app = launch(arguments: ["-debugNarration", "hindi-Dharam_Aur_Anand-1"])
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["narration.done"].waitForExistence(timeout: 20))
        XCTAssertTrue(control("narration.noTranscript", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Dharam Aur Anand - #1"].exists)
        XCTAssertFalse(app.buttons["narration.translate"].exists)
        XCTAssertFalse(app.buttons["narration.play"].exists)
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
            "-debugPlayerDiscourse", "hindi-Maha_Geeta-5", "-debugNarrationOptions", "-settings.appearance", "dark",
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
        let footer = control("narration.listenStatus", in: app)
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
    func testDownloadsLastRowClearsMiniPlayerAtLargeText() throws {
        try requireTranslationRuntime()
        let app = launch(arguments: [
            "-debugPlayerDiscourse", "english-A_Bird_on_the_Wing__-1", "-debugMiniPlayer", "1",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL",
        ])
        defer { app.terminate() }
        XCTAssertTrue(control("player.mini", in: app).waitForExistence(timeout: 20))
        app.openDestination("Downloads")
        let last = app.staticTexts["Bookmarks"]
        reveal(last, in: app)
        app.swipeUp()
        let mini = control("player.mini", in: app)
        XCTAssertTrue(last.isHittable)
        XCTAssertLessThanOrEqual(last.frame.maxY, mini.frame.minY + 1)
        capture(app, name: "Downloads with mini player")
    }

    @MainActor
    func testLanguageListExplainsHowToGetMoreLanguagesAndVoices() throws {
        try requireTranslationRuntime()
        let app = launch(arguments: ["-debugNarration", "hindi-Maha_Geeta-5", "-debugNarrationOptions", "-settings.appearance", "light"])
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["narration.done"].waitForExistence(timeout: 20))
        let refresh = app.buttons["narration.refreshLanguages"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 10))
        XCTAssertLessThan(refresh.frame.minY, app.frame.midY, "Refresh isn't near the top")
        waitForLanguageCheck(in: app)
        let help = control("narration.moreLanguagesAndVoices", in: app)
        guard help.waitForExistence(timeout: 5) else { throw XCTSkip("This simulator offers no translation languages") }
        reveal(help, in: app)
        help.tap()
        let voices = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Read & Speak")).firstMatch
        let languages = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Apps › Translate")).firstMatch
        XCTAssertTrue(voices.waitForExistence(timeout: 5))
        XCTAssertTrue(languages.exists)
        capture(app, name: "How to get more languages and voices")
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
            XCTAssertTrue(app.navigationBars["Listen in Translation"].exists)
            XCTAssertTrue(app.staticTexts[title].exists)
            XCTAssertTrue(control("narration.preparation", in: app).exists)
            waitForLanguageCheck(in: app)
            let explanation = control("narration.explanation", in: app)
            reveal(explanation, in: app)
            XCTAssertTrue(explanation.exists)
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
    func testVoiceChoiceReturnsToListeningWithoutOpeningAReader() throws {
        try requireTranslationRuntime()
        let app = launch(arguments: ["-debugNarration", "hindi-Maha_Geeta-5", "-debugNarrationOptions"])
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["narration.done"].waitForExistence(timeout: 20))
        waitForLanguageCheck(in: app)
        let voice = app.buttons["narration.voice"]
        guard voice.exists else { throw XCTSkip("This simulator has no compatible translation voices") }
        reveal(voice, in: app)
        voice.tap()
        XCTAssertTrue(app.navigationBars["Voice"].waitForExistence(timeout: 5))
        let preview = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "narration.voicePreview.")).firstMatch
        XCTAssertTrue(preview.exists)
        let choice = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "narration.voiceChoice.")).firstMatch
        XCTAssertTrue(choice.exists)
        choice.tap()
        capture(app, name: "Compare translated voices")
        app.navigationBars["Voice"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Listen in Translation"].waitForExistence(timeout: 5))
        let action = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["narration.translate", "narration.play"])).firstMatch
        reveal(action, in: app)
        XCTAssertTrue(action.exists)
        XCTAssertFalse(control("narration.reader", in: app).exists)
        capture(app, name: "One translation listening screen")
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
        // A saved version folds its options into one summary line.
        XCTAssertTrue(control("narration.targetLanguage", in: app).exists || control("narration.unavailable", in: app).exists
            || control("narration.versionSummary", in: app).exists)
        // Without translation only audio that's already saved can be offered.
        if control("narration.unavailable", in: app).exists {
            let translate = app.buttons["narration.translate"]
            XCTAssertFalse(translate.exists && translate.isEnabled, "Offered to translate without translation")
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
            // An element half under the top bar still sits in the upper half, so the content must move down.
            let upward = !element.exists || element.frame.midY > app.frame.midY
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
