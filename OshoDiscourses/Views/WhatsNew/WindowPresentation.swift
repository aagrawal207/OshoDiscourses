import SwiftUI
import UIKit

/// SwiftUI cannot see sheets that other screens present, and a second modal in the same window fails.
@MainActor
enum WindowPresentation {
    /// In the foreground with nothing presented over it.
    static func isQuiet(_ window: UIWindow?) -> Bool {
        guard let window, window.windowScene?.activationState == .foregroundActive else { return false }
        return window.rootViewController?.presentedViewController == nil
    }
}

/// Reports the UIKit window hosting a SwiftUI view, so checks stay scoped to that window.
struct HostWindowReader: UIViewRepresentable {
    let onChange: (UIWindow?) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = onChange
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) { uiView.onChange = onChange }

    final class ProbeView: UIView {
        var onChange: ((UIWindow?) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            onChange?(window)
        }
    }
}

/// Holds the window weakly; SwiftUI state must not keep a closed window alive.
@MainActor
final class HostWindowBox {
    weak var window: UIWindow?
}
