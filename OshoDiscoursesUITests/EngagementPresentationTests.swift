import StoreKitTest
import XCTest

final class EngagementPresentationTests: XCTestCase {
    @MainActor
    func testSupportSheetOpensWithoutReofferingCardOnReturn() throws {
        let session = try storeSession()
        defer { session.clearTransactions() }
        let app = launch(suite: "EngagementUITests.\(UUID().uuidString)")
        defer { app.terminate() }
        let support = app.buttons["home.supportDevelopment"]
        XCTAssertTrue(support.waitForExistence(timeout: 20), app.debugDescription)
        capture(app, "Home optional support")
        support.tap()
        XCTAssertTrue(app.navigationBars["Support Development"].waitForExistence(timeout: 15))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["home.supportDevelopment"].exists)
    }

    @MainActor
    func testNotNowAndPermanentDismissalPersistAcrossRelaunch() throws {
        let session = try storeSession()
        defer { session.clearTransactions() }
        for button in ["home.supportNotNow", "home.supportNever"] {
            let app = launch(suite: "EngagementUITests.\(UUID().uuidString)")
            XCTAssertTrue(app.buttons[button].waitForExistence(timeout: 20))
            app.buttons[button].tap()
            XCTAssertFalse(app.buttons["home.supportDevelopment"].exists)
            app.terminate()
            app.launch()
            XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons["home.supportDevelopment"].waitForExistence(timeout: 3))
            app.terminate()
        }
    }

    @MainActor
    func testLargeTextActionsAndPlaybackSuppression() throws {
        let session = try storeSession()
        defer { session.clearTransactions() }
        let app = launch(suite: "EngagementUITests.\(UUID().uuidString)", extra: [
            "-settings.appearance", "dark",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        defer { app.terminate() }
        let never = app.buttons["home.supportNever"]
        for _ in 0..<6 {
            if never.exists && never.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(never.isHittable)
        capture(app, "Home support large text")
        never.tap()
        app.terminate()

        app.launchArguments = ["-debugEstablishedListener", "-debugEngagementSuite", "EngagementUITests.\(UUID().uuidString)",
                               "-debugPlaySample", "english-A_Bird_on_the_Wing__-1", "-debugMiniPlayer", "1"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["player.mini"].waitForExistence(timeout: 10) || app.otherElements["player.mini"].exists)
        XCTAssertFalse(app.buttons["home.supportDevelopment"].exists)
    }

    private func storeSession() throws -> SKTestSession {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TipJar", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        return session
    }

    @MainActor
    private func launch(suite: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-debugEstablishedListener", "-debugEngagementSuite", suite] + extra
        app.launch()
        return app
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
