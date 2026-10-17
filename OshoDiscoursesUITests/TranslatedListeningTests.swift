import XCTest

#if TRANSLATED_NARRATION
final class TranslatedListeningTests: XCTestCase {
    @MainActor
    func testTranslatedSeriesSelectsSupportedLanguagesWithoutDownloadingOriginal() throws {
        guard #available(macCatalyst 26.0, *) else { throw XCTSkip("Apple Translation requires Mac Catalyst 26") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-settings.languageFilter", "Hindi", "-debugNarrationOptions"]
        app.launch()
        defer { app.terminate() }

        app.openDestination("Library")
        let chip = app.buttons["Translated to Hindi"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        chip.tap()
        let series = app.staticTexts["A Bird on the Wing"]
        XCTAssertTrue(series.waitForExistence(timeout: 10))
        capture(app, name: "Library translated to Hindi")
        series.tap()

        let selector = app.buttons["series.listeningLanguage"]
        XCTAssertTrue(selector.waitForExistence(timeout: 10))
        XCTAssertFalse(app.segmentedControls["series.listeningLanguage"].exists)
        let loaded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "NOT (value CONTAINS %@)", "checking translation languages"), object: selector
        )
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 30), .completed)
        selector.tap()
        let targets = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "series.listeningTarget."))
        guard targets.firstMatch.waitForExistence(timeout: 30) else {
            if app.staticTexts["No translation languages available"].exists {
                throw XCTSkip("This runtime reports no supported translation pairs")
            }
            XCTFail("The language menu did not finish loading supported targets")
            return
        }
        XCTAssertFalse(app.buttons["series.listeningTarget.en"].exists)
        let hindi = app.buttons["series.listeningTarget.hi"]
        let firstTarget = hindi.exists ? hindi : targets.firstMatch
        let firstTargetID = firstTarget.identifier
        let firstName = languageName(firstTarget)
        firstTarget.tap()
        XCTAssertEqual(selector.value as? String, firstName)
        let downloadAll = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Download All")).firstMatch
        XCTAssertFalse(downloadAll.exists)
        let firstRow = app.descendants(matching: .any)["series.discourse.english-A_Bird_on_the_Wing__-1"].firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10))
        capture(app, name: "English series in a supported translation language")
        firstRow.tap()

        XCTAssertTrue(app.buttons["narration.done"].waitForExistence(timeout: 10))
        let language = app.descendants(matching: .any)["narration.targetLanguage"]
        let summary = app.descendants(matching: .any)["narration.versionSummary"]
        if summary.waitForExistence(timeout: 5) {
            XCTAssertTrue(summary.label.contains(firstName), "The saved version shown isn't in the chosen language")
        } else if language.waitForExistence(timeout: 20) {
            XCTAssertTrue((language.value as? String)?.contains(firstName) == true || language.label.contains(firstName))
            XCTAssertTrue(app.descendants(matching: .any)["narration.pace"].exists)
        }
        capture(app, name: "Translated narration sheet from the series page")
        app.buttons["narration.done"].tap()

        selector.tap()
        let anotherTarget = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier != %@", "series.listeningTarget.", firstTargetID
        )).firstMatch
        XCTAssertTrue(anotherTarget.waitForExistence(timeout: 10))
        let anotherName = languageName(anotherTarget)
        anotherTarget.tap()
        XCTAssertEqual(selector.value as? String, anotherName)
        XCTAssertFalse(downloadAll.exists)
        XCTAssertEqual(firstRow.value as? String, "\(anotherName) translation")

        // Changing targets keeps translated rows; only Original restores recording actions.
        selector.tap()
        let original = app.buttons["series.listeningOriginal"]
        XCTAssertTrue(original.label.contains("Osho's original recording"))
        original.tap()
        XCTAssertTrue(downloadAll.waitForExistence(timeout: 5))
    }

    private func languageName(_ button: XCUIElement) -> String {
        button.label.replacingOccurrences(of: " (voice needed)", with: "")
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
