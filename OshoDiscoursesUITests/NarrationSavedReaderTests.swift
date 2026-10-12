import XCTest

#if TRANSLATED_NARRATION
final class NarrationSavedReaderTests: XCTestCase {
    private struct Fixture {
        let discourseID: String
        let renditionID: String
        let segmentStart: TimeInterval
    }

    private func fixture() throws -> Fixture {
        let environment = ProcessInfo.processInfo.environment
        guard let discourse = environment["OSHO_NARRATION_SOURCE_ID"],
              let rendition = environment["OSHO_NARRATION_RENDITION_ID"],
              let value = environment["OSHO_NARRATION_SEGMENT_START"], let start = Double(value) else {
            throw XCTSkip("Requires a verified native fixture from seed-reader.py")
        }
        return Fixture(discourseID: discourse, renditionID: rendition, segmentStart: start)
    }

    @MainActor
    func testNativeAudioReaderSeeksAndResumesItsOwnPosition() throws {
        let fixture = try fixture()
        let app = XCUIApplication()
        app.launchArguments = ["-debugNarration", fixture.discourseID, "-settings.smartDownload", "0",
                               "-settings.smartDelete", "0", "-settings.defaultPlaybackRate", "1"]
        app.launch()
        defer { app.terminate() }
        let play = app.buttons["narration.play.\(fixture.renditionID)"]
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        play.tap()
        let pause = app.buttons["Pause narration"]
        XCTAssertTrue(pause.waitForExistence(timeout: 15))
        pause.tap()
        let passage = app.buttons["narration.segment.2"]
        reveal(passage, in: app)
        passage.tap()
        XCTAssertTrue(app.buttons["Play narration"].exists)
        XCTAssertEqual(elapsed(in: app), fixture.segmentStart, accuracy: 1.1)
        capture(app, "Native narration paused at a selected passage")

        app.terminate()
        app.launch()
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        let started = Date()
        play.tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 15))
        pause.tap()
        let resumed = elapsed(in: app)
        XCTAssertGreaterThanOrEqual(resumed, fixture.segmentStart - 1)
        XCTAssertLessThanOrEqual(resumed, fixture.segmentStart + Date().timeIntervalSince(started) * 2 + 2)
        capture(app, "Native narration resumed after app relaunch")
        app.buttons["narration.returnToOriginal"].tap()
        XCTAssertTrue(app.buttons["narration.done"].waitForNonExistence(timeout: 10))
        let mini = app.descendants(matching: .any).matching(identifier: "player.mini").firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 10))
        mini.tap()
        XCTAssertTrue(app.buttons["player.audioEnhancement"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["player.transcript"].exists)
        XCTAssertFalse(app.buttons["player.readNarration"].exists)
    }

    @MainActor
    func testNativeRenditionOpensFromTheSavedLibrary() throws {
        let fixture = try fixture()
        let app = XCUIApplication()
        app.launchArguments = ["-settings.smartDownload", "0", "-settings.smartDelete", "0", "-settings.defaultPlaybackRate", "1"]
        app.launch()
        defer { app.terminate() }
        app.openDestination("Downloads")
        let library = app.descendants(matching: .any).matching(identifier: "downloads.translatedNarrations").firstMatch
        reveal(library, in: app)
        library.tap()
        let row = app.buttons["narration.library.\(fixture.renditionID)"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["narration.startPlayback"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["narration.segment.0"].exists)
        capture(app, "Saved native narration opened from the library")
    }

    @MainActor
    private func elapsed(in app: XCUIApplication) -> TimeInterval {
        let progress = app.descendants(matching: .any).matching(identifier: "narration.playbackProgress").firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        let value = (progress.value as? String) ?? progress.label
        let clock = value.components(separatedBy: " of ").first ?? ""
        let components = clock.split(separator: ":").compactMap { Double($0) }
        guard components.count == 2 else { XCTFail("Unexpected narration progress: \(value)"); return -1 }
        return components[0] * 60 + components[1]
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTFail("Native narration control is unreachable: \(element)")
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
