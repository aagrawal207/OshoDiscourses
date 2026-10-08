import XCTest

/// Needs network: the transcript is fetched from oshoworld.com on first open.
final class TranscriptSelectionTests: XCTestCase {
    // A long press on a draggable row leaves XCTest waiting about a minute for
    // animations while the app sits idle, so only the menu checks press rows.

    @MainActor
    func testRowMenuOffersCopyOptionsAndStartsSelection() throws {
        let app = launchTranscript()
        defer { app.terminate() }
        app.descendants(matching: .any)["transcript.row.0"].press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Select Text"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Copy"].exists)
        XCTAssertTrue(app.buttons["Share"].exists)
        capture(app, name: "Transcript row menu")
        app.buttons["Select Passages"].tap()
        expect(app.staticTexts["transcript.selection.count"], label: "1 selected")
    }

    @MainActor
    func testPassagesCanBePickedCopiedAndOpenedForWordSelection() throws {
        let app = launchTranscript()
        defer { app.terminate() }
        func row(_ ordinal: Int) -> XCUIElement { app.descendants(matching: .any)["transcript.row.\(ordinal)"] }

        app.buttons["Transcript options"].tap()
        app.buttons["Select Passages"].tap()
        let count = app.staticTexts["transcript.selection.count"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        expect(count, label: "Tap passages")
        tapVisible(row(0), in: app)
        tapVisible(row(1), in: app)
        tapVisible(row(2), in: app)
        expect(count, label: "3 selected")
        tapVisible(row(1), in: app)
        expect(count, label: "2 selected")
        capture(app, name: "Transcript passages selected")

        app.buttons["transcript.selection.selectText"].tap()
        let body = app.textViews["transcript.selectText.body"]
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        let text = body.value as? String ?? ""
        XCTAssertTrue(text.contains("LIKE THIS CUP,\n\nYou have come"), "Skipped rows should leave a paragraph break: \(text.prefix(300))")
        XCTAssertFalse(text.contains("YOU ARE FULL OF YOUR OWN"))
        capture(app, name: "Select Text sheet")
        app.buttons["transcript.selectText.done"].tap()

        app.buttons["transcript.selection.copy"].tap()
        XCTAssertTrue(app.staticTexts["Copied 2 passages"].waitForExistence(timeout: 3))
        XCTAssertTrue(count.waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testSelectUpToHereFillsTheGap() throws {
        let app = launchTranscript(extraArguments: ["-debugTranscriptSelecting", "0", "0"])
        defer { app.terminate() }
        let count = app.staticTexts["transcript.selection.count"]
        expect(count, label: "1 selected")
        let row = app.descendants(matching: .any)["transcript.row.2"]
        reveal(row, in: app)
        row.press(forDuration: 1.0)
        let upToHere = app.buttons["Select Up to Here"]
        XCTAssertTrue(upToHere.waitForExistence(timeout: 5))
        upToHere.tap()
        expect(count, label: "3 selected")
    }

    /// The search field accepts text drops, so it shows what a drag carries. It opens
    /// from launch arguments, keeping the keyboard from covering the rows.
    @MainActor
    func testDraggingARowCarriesItsText() throws {
        let app = launchTranscript(extraArguments: ["-debugTranscriptSearch", "qqzz"])
        defer { app.terminate() }
        let field = app.textFields["Find in transcript"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let row = app.descendants(matching: .any)["transcript.row.3"]
        bringNearTop(row, in: app)
        dragHeld(row, to: field)
        expectValue(of: field, containing: ["If you feel that you are empty"])
        capture(app, name: "Row dropped into search")
    }

    @MainActor
    func testDraggingAPickedRowCarriesTheWholeSelection() throws {
        let app = launchTranscript(extraArguments: ["-debugTranscriptSearch", "qqzz", "-debugTranscriptSelecting", "3", "4"])
        defer { app.terminate() }
        let field = app.textFields["Find in transcript"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        expect(app.staticTexts["transcript.selection.count"], label: "2 selected")
        let row = app.descendants(matching: .any)["transcript.row.3"]
        bringNearTop(row, in: app)
        dragHeld(row, to: field)
        expectValue(of: field, containing: ["If you feel that you are empty", "Only the name has changed"])
        capture(app, name: "Selection dropped into search")
    }

    @MainActor
    private func launchTranscript(extraArguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-debugPlayerDiscourse", "english-A_Bird_on_the_Wing__-1",
            "-settings.transcriptSentenceLayout", "1",
            "-settings.appearance", "light",
        ] + extraArguments
        app.launch()
        let transcriptButton = app.buttons["player.transcript"]
        XCTAssertTrue(transcriptButton.waitForExistence(timeout: 20))
        if !app.isPad { transcriptButton.tap() }
        XCTAssertTrue(app.descendants(matching: .any)["transcript.row.0"].waitForExistence(timeout: 30), "Transcript did not load")
        return app
    }

    /// A row near the top gets its menu below it, so a drag up to the search field
    /// does not pass over the menu, which iOS would treat as choosing an item.
    @MainActor
    private func bringNearTop(_ row: XCUIElement, in app: XCUIApplication) {
        let field = app.textFields["Find in transcript"]
        let header = max(app.buttons["Search transcript"].frame.maxY, field.exists ? field.frame.maxY : 0)
        let startY = app.frame.maxY - 260
        for _ in 0..<6 {
            let offset = row.exists ? row.frame.minY - (header + 40) : 200
            if row.exists, abs(offset) < 30 { return }
            let distance = min(max(offset, -200), startY - header - 20)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: app.frame.midX, dy: startY)).press(
                forDuration: 0,
                thenDragTo: origin.withOffset(CGVector(dx: app.frame.midX, dy: startY - distance)),
                withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        XCTFail("Row did not reach the top: \(row)")
    }

    /// Holds until the menu has lifted the row, then moves slowly and pauses on the
    /// target; a quick synthesized drag can finish before the lift. The menu hangs
    /// from the row's leading edge, so the path runs down the trailing side.
    @MainActor
    private func dragHeld(_ row: XCUIElement, to target: XCUIElement) {
        let from = row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        let to = target.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        from.press(forDuration: 2.5, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.8)
    }

    private func expectValue(of field: XCUIElement, containing parts: [String]) {
        let matches = NSPredicate { object, _ in
            let value = (object as? XCUIElement)?.value as? String ?? ""
            return parts.allSatisfy(value.contains)
        }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: matches, object: field)], timeout: 8)
        XCTAssertEqual(result, .completed, "Dropped text was \(field.value ?? "nil")")
    }

    /// Brings the point 20 pt into a row (where `tapVisible` taps) between the
    /// reader's header and the bottom bar, so a tap cannot land on either bar.
    @MainActor
    private func reveal(_ row: XCUIElement, in app: XCUIApplication) {
        // Below the reader's header and search bar, whether in a sheet or the iPad pane.
        let field = app.textFields["Find in transcript"]
        let header = max(app.buttons["Search transcript"].frame.maxY, field.exists ? field.frame.maxY : 0)
        let top = header + 12, bottom = app.frame.maxY - 220
        for _ in 0..<10 {
            if row.exists, row.frame.minY + 20 >= top, row.frame.minY + 40 <= bottom { return }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            let dy = !row.exists || row.frame.minY + 40 > bottom ? -0.3 : 0.15
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
