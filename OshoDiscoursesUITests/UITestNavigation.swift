import XCTest

extension XCUIApplication {
    /// Opens a top-level destination from the phone's tab bar or the iPad sidebar.
    @MainActor
    func openDestination(_ title: String, timeout: TimeInterval = 20) {
        let tab = tabBars.buttons[title]
        let cell = cells.containing(.staticText, identifier: title).firstMatch
        // iPad's top tab bar exposes its items as plain buttons outside `tabBars`.
        let topTab = buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if tab.exists, tab.isHittable { tab.tap(); return }
            if cell.exists, cell.isHittable { cell.tap(); return }
            if topTab.exists, topTab.isHittable { topTab.tap(); return }
            _ = tab.waitForExistence(timeout: 0.5)
        }
        XCTFail("No tab or sidebar item named \(title)")
    }

    var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
}
