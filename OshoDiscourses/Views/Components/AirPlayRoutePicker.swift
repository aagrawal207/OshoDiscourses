import SwiftUI
import AVKit

/// Wraps `AVRoutePickerView` (the system AirPlay button) so it can sit in the
/// SwiftUI player. Tapping it presents Apple's standard output-route chooser —
/// AirPods, HomePods, Apple TVs, Bluetooth speakers — the same picker the OS
/// shows elsewhere, so there's nothing custom to maintain.
struct AirPlayRoutePicker: UIViewRepresentable {
    var tintColor: UIColor

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = tintColor
        // Show the "active route" highlight (the icon turns the tint color while a
        // remote route is selected), matching Music/Podcasts behavior.
        view.activeTintColor = tintColor
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = tintColor
        uiView.activeTintColor = tintColor
    }
}
