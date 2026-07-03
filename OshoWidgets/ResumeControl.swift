import WidgetKit
import AppIntents
import SwiftUI

/// A Control Center / Lock Screen control that opens Discourse Player and
/// resumes the last discourse. The user adds it from the Controls gallery
/// (there is no API to pre-place it). It's a launcher, not a transport control —
/// play/pause of already-playing audio comes from the system media controls.
struct ResumeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.agraabhi.oshodiscourses.resume") {
            ControlWidgetButton(action: ResumePlaybackIntent()) {
                Label("Resume Discourse", systemImage: "play.circle")
            }
        }
        .displayName("Resume Discourse")
        .description("Open Discourse Player and resume playback.")
    }
}
