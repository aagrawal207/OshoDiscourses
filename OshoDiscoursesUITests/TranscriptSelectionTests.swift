import XCTest

/// Needs network: the transcript is fetched from oshoworld.com on first open.
final class TranscriptSelectionTests: XCTestCase {
    @MainActor
    func testPassagesCanBePickedCopiedAndOpenedForWordSelection() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-debugPlayerDiscourse", "english-A_Bird_on_the_Wing__-1",
            "-settings.transcriptSentenceLayout", "1",
            "-settings.appearance", "light",
        ]
        app.launch()
        defer { app.terminate() }

        let transcriptButton = app.buttons["player.transcript"]
        XCTAssertTrue(transcriptButton.waitForExistence(timeout: 20))
        if !app.isPad { transcriptButton.tap() }
        func row(_ ordinal: Int) -> XCUIElement { app.descendants(matching: .any)["transcript.row.\(ordinal)"] }
        XCTAssertTrue(row(0).waitForExistence(timeout: 30), "Transcript did not load")

        // Long-press offers the copy options without opening select mode.
        row(0).press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Select Text"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Copy"].exists)
        capture(app, name: "Transcript row menu")
        app.buttons["Select Passages"].tap()

        let count = app.staticTexts["transcript.selection.count"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        expect(count, label: "1 selected")
        tapVisible(row(1), in: app)
        tapVisible(row(2), in: app)
        expect(count, label: "3 selected")
        tapVisible(row(1), in: app)
        expect(count, label: "2 selected")
        capture(app, name: "Transcript passages selected")

        // "Select Up to Here" fills the gap back in.
        reveal(row(1), in: app)
        row(1).press(forDuration: 1.0)
        let upToHere = app.buttons["Select Up to Here"]
        XCTAssertTrue(upToHere.waitForExistence(timeout: 5))
        upToHere.tap()
        expect(count, label: "3 selected")

        app.buttons["transcript.selection.selectText"].tap()
        let body = app.textViews["transcript.selectText.body"]
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        XCTAssertGreaterThan((body.value as? String)?.count ?? 0, 40)
        capture(app, name: "Select Text sheet")
        app.buttons["transcript.selectText.done"].tap()

        app.buttons["transcript.selection.copy"].tap()
        XCTAssertTrue(app.staticTexts["Copied 3 passages"].waitForExistence(timeout: 3))
        XCTAssertTrue(count.waitForNonExistence(timeout: 3))
    }

    /// Brings a row's top into the band between the navigation bar and the
    /// selection bar, then taps near its top so the tap cannot land on a bar.
    @MainActor
    private func reveal(_ row: XCUIElement, in app: XCUIApplication) {
        // Below the reader's header, whether it is a sheet's bar or the iPad pane's.
        let top = app.buttons["Search transcript"].frame.maxY + 24, bottom = app.frame.maxY - 220
        for _ in 0..<10 {
            if row.exists, row.frame.minY >= top, row.frame.minY + 30 <= bottom { return }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            let dy = !row.exists || row.frame.minY + 30 > bottom ? -0.3 : 0.15
            start.press(forDuration: 0, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6 + dy)), withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        XCTFail("Row never became visible: \(row)")
    }

    @MainActor
    private func tapVisible(_ row: XCUIElement, in app: XCUIApplication) {
        reveal(row, in: app)
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 20)).tap()
    }

    private func expect(_ element: XCUIElement, label: String) {
        let matches = NSPredicate(format: "label == %@", label)
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: matches, object: element)], timeout: 5)
        XCTAssertEqual(result, .completed, "Expected \(label), found \(element.label)")
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
