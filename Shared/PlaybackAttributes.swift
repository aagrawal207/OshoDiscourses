import ActivityKit
import Foundation

struct PlaybackAttributes: ActivityAttributes {
    var seriesName: String
    var totalTracks: Int

    struct ContentState: Codable, Hashable {
        var title: String
        var trackNumber: Int
        var isPlaying: Bool
        var elapsedSeconds: Double
        var durationSeconds: Double
        var playbackRate: Float
    }
}
