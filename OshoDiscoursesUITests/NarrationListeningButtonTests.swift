import XCTest

#if TRANSLATED_NARRATION
/// Taps every control on the listening screen against a seeded native rendition
/// (Tools/NarrationTranslationProbe/seed-reader.py) and records what each one did.
final class NarrationListeningButtonTests: XCTestCase {
    private var sourceID = ""
    private var renditionID = ""

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let source = environment["OSHO_NARRATION_SOURCE_ID"],
              let rendition = environment["OSHO_NARRATION_RENDITION_ID"] else {
            throw XCTSkip("Requires a verified native fixture from seed-reader.py")
        }
        sourceID = source
        renditionID = rendition
    }

    @MainActor
    func testEveryListeningControlDoesWhatItSays() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-debugNarration", sourceID, "-debugNarrationOptions", "-settings.appearance", "light",
                               "-settings.smartDownload", "0", "-settings.smartDelete", "0", "-settings.defaultPlaybackRate", "1"]
        app.launch()
        defer { app.terminate() }
        let primary = app.buttons["narration.play"]
        XCTAssertTrue(primary.waitForExistence(timeout: 20))
        capture(app, "01 Opened with a saved translation")

        // A discourse with saved audio opens on that audio, ready to play, with its options folded into one line.
        let readAlongOnOpen = app.buttons["narration.readAlong"]
        reveal(readAlongOnOpen, in: app)
        XCTAssertTrue(readAlongOnOpen.exists, "Saved audio isn't offered on open")
        XCTAssertEqual(control("narration.listenStatus", in: app).label, "Saved · plays offline")
        XCTAssertFalse(app.buttons["narration.translate"].exists, "A finished translation offered to translate again")
        XCTAssertFalse(control("narration.heatWarning", in: app).exists, "Warned about heat with nothing to translate")
        XCTAssertTrue(control("narration.versionSummary", in: app).label.contains("Hindi"))
        XCTAssertFalse(control("narration.targetLanguage", in: app).exists, "Options weren't folded away")

        tapRevealed(primary, in: app)
        XCTAssertTrue(waitForLabel(primary, "Pause"), "Listen didn't start the saved audio")
        let elapsed = control("narration.elapsed", in: app)
        XCTAssertTrue(elapsed.waitForExistence(timeout: 5))
        capture(app, "02 Playing")

        // Resuming continues from the last saved position, so start the skips from the beginning.
        reveal(app.sliders.firstMatch, in: app)
        app.sliders.firstMatch.adjust(toNormalizedSliderPosition: 0)
        XCTAssertLessThan(seconds(elapsed), 12, "Dragging the slider didn't move playback")
        // Skips are checked while paused, so scrolling time can't blur them.
        tapRevealed(primary, in: app)
        XCTAssertTrue(waitForLabel(primary, "Resume"), "Pause didn't pause, or the paused label is unclear")
        capture(app, "03 Paused")
        reveal(elapsed, in: app)
        let before = seconds(elapsed)
        tapRevealed(app.buttons["narration.skipForward"], in: app)
        capture(app, "02b After skip forward")
        XCTAssertEqual(seconds(elapsed), before + 30, accuracy: 1.5, "Skip forward didn't move playback")
        tapRevealed(app.buttons["narration.skipBack"], in: app)
        XCTAssertEqual(seconds(elapsed), before + 15, accuracy: 1.5, "Skip back didn't move playback")
        reveal(app.sliders.firstMatch, in: app)
        app.sliders.firstMatch.adjust(toNormalizedSliderPosition: 0)
        tapRevealed(primary, in: app)
        XCTAssertTrue(waitForLabel(primary, "Pause"))

        tapRevealed(app.buttons["narration.speed"], in: app)
        XCTAssertTrue(app.staticTexts["Speed"].waitForExistence(timeout: 5), "Speed didn't open")
        capture(app, "04 Speed")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        XCTAssertTrue(app.staticTexts["Speed"].waitForNonExistence(timeout: 5), "Speed couldn't be closed")
        XCTAssertTrue(app.buttons["narration.done"].exists, "Closing Speed closed the listening screen")

        tapRevealed(app.buttons["narration.sleepTimer"], in: app)
        XCTAssertTrue(app.buttons["15 min"].waitForExistence(timeout: 5), "Sleep timer didn't open")
        capture(app, "05 Sleep timer")
        app.buttons["15 min"].tap()
        XCTAssertTrue(app.buttons["15 min"].waitForNonExistence(timeout: 5))
        XCTAssertNotEqual(app.buttons["narration.sleepTimer"].value as? String, "Off", "Sleep timer didn't start")

        tapRevealed(app.buttons["narration.changeOptions"], in: app)
        let preview = app.buttons["narration.previewVoice"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5), "Change didn't show the voice options")
        XCTAssertTrue(preview.isEnabled, "Preview is unavailable while listening")
        tapRevealed(preview, in: app)
        XCTAssertTrue(waitForLabel(preview, "Stop preview"), "Preview didn't start")
        XCTAssertTrue(waitForLabel(primary, "Resume"), "Preview didn't pause the translation")
        capture(app, "06 Previewing a voice")
        tapRevealed(preview, in: app)
        XCTAssertTrue(waitForLabel(preview, "Preview voice"), "Stop preview didn't stop")

        let readAlong = app.buttons["narration.readAlong"]
        reveal(readAlong, in: app)
        readAlong.tap()
        XCTAssertTrue(control("narration.reader", in: app).waitForExistence(timeout: 5), "Read along didn't open")
        capture(app, "07 Read along")
        app.buttons["narration.showVariants"].tap()
        XCTAssertTrue(primary.waitForExistence(timeout: 5), "Couldn't get back from read along")

        // Changing pace means a different version that isn't prepared yet.
        let pace = app.buttons["narration.pace"]
        choosePace("Osho's pace", picker: pace, in: app)
        let status = control("narration.listenStatus", in: app)
        reveal(status, in: app)
        XCTAssertTrue(waitForLabel(status, "Not prepared yet", contains: true),
                      "Changing pace didn't explain that this version needs preparing")
        let translate = app.buttons["narration.translate"]
        reveal(translate, in: app)
        XCTAssertTrue(translate.label.hasPrefix("Translate into"))
        XCTAssertFalse(primary.exists, "Offered Play for a version with no audio")
        let heat = control("narration.heatWarning", in: app)
        reveal(heat, in: app)
        XCTAssertTrue(heat.label.contains("may get warm"), "Translating didn't warn that the phone may get warm")
        capture(app, "08 A version that isn't prepared")
        choosePace("Natural pace", picker: pace, in: app)
        capture(app, "08b Back to natural pace")
        XCTAssertTrue(waitForLabel(primary, "Resume"), "Switching back didn't find the saved version")

        tapRevealed(app.buttons["narration.voice"], in: app)
        XCTAssertTrue(app.navigationBars["Voice"].waitForExistence(timeout: 5), "Voice didn't open")
        capture(app, "09 Voices")
        app.navigationBars["Voice"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(primary.waitForExistence(timeout: 5))
        tapRevealed(app.buttons["narration.hideOptions"], in: app)
        XCTAssertTrue(control("narration.versionSummary", in: app).waitForExistence(timeout: 5), "Hide didn't fold the options")

        let saved = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Saved translations")).firstMatch
        reveal(saved, in: app)
        saved.tap()
        let choose = app.buttons["narration.choose.\(renditionID)"]
        reveal(choose, in: app)
        if !choose.exists {
            // A tap during the list's scroll settle can miss the row.
            reveal(saved, in: app)
            saved.tap()
            reveal(choose, in: app)
        }
        XCTAssertTrue(choose.exists, "Saved versions didn't expand")
        capture(app, "10 Saved versions")
        app.buttons["narration.delete.\(renditionID)"].tap()
        XCTAssertTrue(app.buttons["narration.confirmDelete"].waitForExistence(timeout: 5), "Delete didn't ask first")
        capture(app, "10b Delete asks first")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        XCTAssertTrue(app.buttons["narration.choose.\(renditionID)"].waitForExistence(timeout: 5), "Cancel deleted the translation")

        let original = app.buttons["narration.returnToOriginal"]
        reveal(original, in: app)
        XCTAssertTrue(original.isEnabled)
        original.tap()
        XCTAssertTrue(app.buttons["narration.done"].waitForNonExistence(timeout: 10), "Original recording didn't open the recording")
        let mini = control("player.mini", in: app)
        XCTAssertTrue(mini.waitForExistence(timeout: 10))
        capture(app, "11 Back to the recording")
    }

    @MainActor
    func testTheBackgroundLimitIsExplainedOnlyWhereTranslationIsOffered() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-debugNarration", sourceID, "-debugNarrationOptions", "-settings.appearance", "light"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["narration.play"].waitForExistence(timeout: 20))
        // A finished translation has nothing left to translate.
        XCTAssertFalse(control("narration.backgroundLimit", in: app).exists)

        tapRevealed(app.buttons["narration.changeOptions"], in: app)
        tapRevealed(app.buttons["narration.pace"], in: app)
        app.buttons["Osho's pace"].firstMatch.tap()
        let note = control("narration.backgroundLimit", in: app)
        reveal(note, in: app)
        XCTAssertTrue(note.waitForExistence(timeout: 5), "The iOS background limit wasn't explained beside Translate")
        XCTAssertTrue(note.label.contains("If you play the translation, it keeps translating in the background"))
        capture(app, "Background limit explained")
    }

    @MainActor
    private func waitForLabel(_ element: XCUIElement, _ text: String, contains: Bool = false, timeout: TimeInterval = 5) -> Bool {
        let predicate = contains ? NSPredicate(format: "label CONTAINS %@", text) : NSPredicate(format: "label == %@", text)
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    @MainActor
    private func seconds(_ element: XCUIElement) -> Double {
        let parts = element.label.split(separator: ":").compactMap { Double($0) }
        return parts.count == 2 ? parts[0] * 60 + parts[1] : -1
    }

    @MainActor
    private func control(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Lists render lazily, so a row out of view may not exist yet; search downward, then back up.
    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let top = app.navigationBars.firstMatch.frame.maxY
        func visible() -> Bool { element.exists && element.isHittable && element.frame.minY >= top }
        for _ in 0..<5 where !visible() { app.swipeUp() }
        for _ in 0..<10 where !visible() { app.swipeDown() }
    }

    /// The simulator can show its keyboard over a menu, so the picker opens above the middle of the screen.
    @MainActor
    private func choosePace(_ name: String, picker: XCUIElement, in app: XCUIApplication) {
        reveal(picker, in: app)
        for _ in 0..<4 where picker.frame.midY > app.frame.midY {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.7))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45)))
        }
        picker.tap()
        let option = app.buttons[name].firstMatch
        let tappable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: option)
        XCTAssertEqual(XCTWaiter.wait(for: [tappable], timeout: 5), .completed, "The pace menu didn't offer \(name)")
        option.tap()
    }

    @MainActor
    private func tapRevealed(_ element: XCUIElement, in app: XCUIApplication) {
        reveal(element, in: app)
        element.tap()
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
