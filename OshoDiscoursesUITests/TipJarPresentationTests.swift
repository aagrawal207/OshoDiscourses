import StoreKitTest
import XCTest

final class TipJarPresentationTests: XCTestCase {
    @MainActor
    func testYearlyOptionsExplainBillingAndRestoreWithoutAnExistingPlan() throws {
        let session = try storeSession()
        defer { session.clearTransactions() }
        let app = launch()
        defer { app.terminate() }
        let small = app.buttons["com.agraabhi.oshodiscourses.tip.small"]
        XCTAssertTrue(small.waitForExistence(timeout: 30), app.debugDescription)
        capture(app, "support-light-top")

        let expected = [
            ("tip.small", "One-time tip"),
            ("tip.medium", "One-time tip"),
            ("support.annual5", "Renews yearly"),
            ("tip.large", "One-time tip"),
            ("support.annual10", "Renews yearly"),
            ("support.annual15", "Renews yearly"),
            ("tip.grand", "One-time tip"),
            ("tip.patron", "One-time tip"),
        ]
        for (suffix, billing) in expected {
            let row = app.buttons["com.agraabhi.oshodiscourses.\(suffix)"]
            reveal(row, in: app)
            XCTAssertTrue(row.label.contains(billing), row.label)
            XCTAssertTrue(row.isEnabled)
            if suffix.hasPrefix("support.") { capture(app, "support-light-\(suffix)") }
        }
        let restore = app.buttons["tipJar.restoreSubscription"]
        reveal(restore, in: app)
        capture(app, "support-light-renewal-terms")
        restore.tap()
        XCTAssertTrue(app.staticTexts["No current yearly support subscription was found."].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["tipJar.manageSubscriptions"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testLargeTextDarkAppearanceKeepsYearlyPricesAndActionsReachable() throws {
        let session = try storeSession()
        defer { session.clearTransactions() }
        let app = launch(largeText: true)
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["Support Development"].waitForExistence(timeout: 30))
        for amount in [5, 10, 15] {
            let row = app.buttons["com.agraabhi.oshodiscourses.support.annual\(amount)"]
            reveal(row, in: app)
            XCTAssertTrue(row.label.contains("/ year"), row.label)
            XCTAssertGreaterThanOrEqual(row.frame.minX, app.frame.minX)
            XCTAssertLessThanOrEqual(row.frame.maxX, app.frame.maxX)
            capture(app, "support-dark-large-\(amount)")
        }
        reveal(app.buttons["tipJar.manageSubscriptions"], in: app)
        XCTAssertTrue(app.buttons["tipJar.manageSubscriptions"].isHittable)
        reveal(app.buttons["tipJar.restoreSubscription"], in: app)
        XCTAssertTrue(app.buttons["tipJar.restoreSubscription"].isHittable)
        capture(app, "support-dark-large-actions")
        app.buttons["Done"].tap()
    }

    @MainActor
    func testPurchaseDisablesDuplicateSubscriptionsAndSurvivesAppRelaunch() throws {
        let session = try storeSession()
        defer { session.clearTransactions() }
        let app = launch()
        defer { app.terminate() }
        let annual = app.buttons["com.agraabhi.oshodiscourses.support.annual5"]
        XCTAssertTrue(app.navigationBars["Support Development"].waitForExistence(timeout: 30))
        reveal(annual, in: app)
        annual.tap()
        let thanks = app.alerts["Thank you"]
        XCTAssertTrue(thanks.waitForExistence(timeout: 20))
        thanks.buttons["OK"].tap()
        XCTAssertTrue(annual.label.contains("Current yearly plan"))
        XCTAssertFalse(annual.isEnabled)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationBars["Support Development"].waitForExistence(timeout: 30))
        reveal(annual, in: app)
        XCTAssertTrue(annual.label.contains("Current yearly plan"))
        XCTAssertFalse(annual.isEnabled)
        for amount in [10, 15] {
            let otherPlan = app.buttons["com.agraabhi.oshodiscourses.support.annual\(amount)"]
            reveal(otherPlan, in: app)
            XCTAssertFalse(otherPlan.isEnabled)
        }
        reveal(app.buttons["tipJar.manageSubscriptions"], in: app)
        capture(app, "support-current-plan-after-relaunch")
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
    private func launch(largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-debugTipJar", "-settings.appearance", largeText ? "dark" : "light"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        return app
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<18 {
            if app.launchArguments.contains("-UIPreferredContentSizeCategoryName") {
                // Accessibility rows may be taller than the viewport, so full-frame alignment cannot settle.
                if element.exists && element.isHittable { return }
                app.swipeUp()
                continue
            }
            if element.exists && element.isHittable {
                let top = app.navigationBars["Support Development"].frame.maxY + 4
                let bottom = app.frame.maxY - 24
                let frame = element.frame
                if frame.height > bottom - top || (frame.minY >= top && frame.maxY <= bottom) { return }
                let offset = frame.minY < top ? top - frame.minY : bottom - frame.maxY
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
                start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: offset)))
            } else {
                app.swipeUp()
            }
        }
        XCTFail("Support control is not reachable: \(element)")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
