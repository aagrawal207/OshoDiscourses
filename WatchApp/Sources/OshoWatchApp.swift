import SwiftUI

@main
@MainActor
struct OshoWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchRootView()
        }
        .backgroundTask(.watchConnectivity) {
            await WatchAppSession.shared.receiveBackgroundUpdates()
        }
    }
}
