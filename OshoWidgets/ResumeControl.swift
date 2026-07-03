import WidgetKit
import AppIntents
import SwiftUI

/// Control Center / Lock Screen control that opens Discourse Player and resumes
/// the last discourse. The user adds it from the Controls gallery (no API to
/// pre-place it). It's a launcher, not a transport control — play/pause of
/// already-playing audio comes from the system media controls.
struct ResumeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.agraabhi.oshodiscourses.resume") {
            ControlWidgetButton(action: ResumePlaybackIntent()) {
                Label("Resume Discourse", image: "Lotus")
            }
        }
        .displayName("Resume Discourse")
        .description("Open Discourse Player and resume playback.")
    }
}

/// Control that simply opens the app — no playback. For listeners who want a
/// quick launcher without auto-starting audio.
struct OpenAppControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.agraabhi.oshodiscourses.open") {
            ControlWidgetButton(action: OpenAppIntent()) {
                Label("Open Discourse Player", image: "Lotus")
            }
        }
        .displayName("Open Discourse Player")
        .description("Open Discourse Player.")
    }
}
