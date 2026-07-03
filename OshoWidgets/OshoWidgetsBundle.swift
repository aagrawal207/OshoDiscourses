import WidgetKit
import SwiftUI

/// Entry point for the widget extension. Vends the Control Center control(s).
@main
struct OshoWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ResumeControl()
        OpenAppControl()
    }
}
