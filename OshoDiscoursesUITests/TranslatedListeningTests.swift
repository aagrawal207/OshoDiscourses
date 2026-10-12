import XCTest

#if TRANSLATED_NARRATION
final class TranslatedListeningTests: XCTestCase {
    @MainActor
    func testHindiListenerFindsEnglishTalksAndOpensAHindiNarrationWithoutDownloading() throws {
        guard #available(macCatalyst 26.0, *) else { throw XCTSkip("Apple Translation requires Mac Catalyst 26") }
        continueAfterFailure = false
        let app = XCUIApplication()
        // The argument domain hides per-series choices saved by earlier runs.
        app.launchArguments = ["-settings.languageFilter", "Hindi", "-narration.translatedSeries", "{}"]
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

        // A hidden-language series opens ready to listen in the listener's language.
        let picker = app.segmentedControls["series.listeningLanguage"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        XCTAssertTrue(picker.buttons["Hindi"].isSelected)
        XCTAssertTrue(app.staticTexts["Translated from the transcript and read by a synthetic voice. The recording isn't needed."].exists)
        let downloadAll = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Download All")).firstMatch
        XCTAssertFalse(downloadAll.exists)
        // Rows share their label with their buttons; the globe marks a narration not prepared yet.
        let prepare = app.buttons.matching(identifier: "globe").firstMatch
        XCTAssertTrue(prepare.waitForExistence(timeout: 10))
        capture(app, name: "English series in Hindi")
        prepare.tap()

        XCTAssertTrue(app.buttons["narration.done"].waitForExistence(timeout: 10))
        let language = app.descendants(matching: .any)["narration.targetLanguage"]
        if language.waitForExistence(timeout: 20) {
            XCTAssertTrue((language.value as? String)?.contains("Hindi") == true || language.label.contains("Hindi"))
            XCTAssertTrue(app.descendants(matching: .any)["narration.pace"].exists)
        }
        capture(app, name: "Hindi narration sheet from the series page")
        app.buttons["narration.done"].tap()

        // Switching back restores the recording's own actions for this series.
        picker.buttons["English"].tap()
        XCTAssertTrue(downloadAll.waitForExistence(timeout: 5))
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
