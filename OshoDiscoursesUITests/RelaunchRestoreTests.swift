import XCTest

#if TRANSLATED_NARRATION
/// Plays a seeded translation and a seeded recording, ends the app each time and checks
/// what the relaunch puts back in the mini-player. Needs a seeded simulator, so it skips otherwise.
final class RelaunchRestoreTests: XCTestCase {
    private struct Fixture {
        let renditionID: String
        let recordingID: String
        let captureDirectory: URL?
    }

    private func fixture() throws -> Fixture {
        let environment = ProcessInfo.processInfo.environment
        guard let rendition = environment["OSHO_RESTORE_RENDITION_ID"],
              let recording = environment["OSHO_RESTORE_RECORDING_ID"] else {
            throw XCTSkip("Requires a seeded translation and recording on the simulator")
        }
        return Fixture(
            renditionID: rendition, recordingID: recording,
            captureDirectory: environment["OSHO_RESTORE_CAPTURE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        )
    }

    private let settings = ["-settings.smartDownload", "0", "-settings.smartDelete", "0", "-settings.defaultPlaybackRate", "1"]

    @MainActor
    func testRelaunchRestoresTheLastTranslationThenTheLastRecording() throws {
        let fixture = try fixture()
        let app = XCUIApplication()
        app.launchArguments = settings
        app.launch()
        app.openDestination("Downloads")
        let row = app.descendants(matching: .any).matching(identifier: "downloads.translation.\(fixture.renditionID)").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "The seeded translation isn't in Downloads")
        row.tap()
        let mini = app.descendants(matching: .any).matching(identifier: "player.mini").firstMatch
        XCTAssertTrue(wait(for: mini, value: "Playing", timeout: 20), "The translation didn't start")
        sleep(15)
        capture(app, "01-translation-playing", fixture)
        endApp(app)

        app.launchArguments = settings
        app.launch()
        XCTAssertTrue(wait(for: mini, value: "Paused", timeout: 20), "Nothing was restored")
        XCTAssertTrue(mini.label.contains("Discourse 1 · Hindi translation"), mini.label)
        app.openDestination("Home")
        let homeRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Hindi translation")).firstMatch
        XCTAssertTrue(homeRow.waitForExistence(timeout: 10), "Home doesn't list the translation")
        capture(app, "02-translation-restored-paused", fixture)
        mini.tap()
        let playPause = app.buttons["player.playPause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Hindi translation")).firstMatch.exists)
        capture(app, "03-translation-restored-full-player", fixture)
        playPause.tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 10), "Play didn't resume the translation")
        sleep(3)
        capture(app, "04-translation-resumed", fixture)
        endApp(app)

        app.launchArguments = settings + ["-debugTranscript", fixture.recordingID, "-debugPlayer"]
        app.launch()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 20), "The recording didn't start")
        sleep(15)
        capture(app, "05-recording-playing", fixture)
        endApp(app)

        app.launchArguments = settings
        app.launch()
        XCTAssertTrue(wait(for: mini, value: "Paused", timeout: 20), "Nothing was restored")
        XCTAssertTrue(mini.label.contains("Discourse 2"), mini.label)
        XCTAssertFalse(mini.label.contains("translation"), mini.label)
        capture(app, "06-recording-restored-paused", fixture)
        app.terminate()
    }

    /// Leaves the app the way a listener does, then ends it as the app switcher would.
    @MainActor
    private func endApp(_ app: XCUIApplication) {
        XCUIDevice.shared.press(.home)
        sleep(3)
        app.terminate()
    }

    @MainActor
    private func wait(for element: XCUIElement, value: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.value as? String == value { return true }
            _ = element.waitForExistence(timeout: 0.5)
        }
        return false
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String, _ fixture: Fixture) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = fixture.captureDirectory {
            try? screenshot.pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"))
        }
    }
}
#endif
