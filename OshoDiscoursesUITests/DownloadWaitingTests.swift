import XCTest

final class DownloadWaitingTests: XCTestCase {
    @MainActor
    func testMobileDataWaitIsExplainedAndOneTapContinues() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-debugDownloadNetwork", "cellularOnly", "-settings.allowCellularDownloads", "NO",
            "-debugDownload", "english-Vigyan_Bhairav_Tantra_Vol_1-3", "-debugTab", "downloads",
        ]
        app.launch()
        defer { app.terminate() }
        let notice = app.descendants(matching: .any)["downloads.waitingNotice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Waiting for Wi-Fi"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Downloads use Wi-Fi only. Each discourse is about 20–30 MB."].exists)
        let useMobileData = app.buttons["downloads.useMobileData"]
        XCTAssertTrue(useMobileData.isHittable)
        capture(app, name: "Downloads waiting for Wi-Fi")

        useMobileData.tap()
        XCTAssertTrue(notice.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Waiting for Wi-Fi"].exists)
        app.openDestination("Settings")
        let toggle = app.switches["Download over Cellular"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "1")
    }

    @MainActor
    func testOfflineWaitHasNoMobileDataAction() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-debugDownloadNetwork", "offline",
            "-debugDownload", "english-Vigyan_Bhairav_Tantra_Vol_1-3", "-debugTab", "downloads",
        ]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.descendants(matching: .any)["downloads.waitingNotice"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Waiting for a connection"].firstMatch.exists)
        XCTAssertFalse(app.buttons["downloads.useMobileData"].exists)
        capture(app, name: "Downloads waiting for a connection")
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
