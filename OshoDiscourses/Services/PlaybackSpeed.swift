import Foundation

/// Playback speed is a continuous setting in 0.05 steps, so 0.85× and 1.1× are as reachable as 1.5×.
enum PlaybackSpeed {
    static let range: ClosedRange<Float> = 0.5...2.0
    static let step: Float = 0.05
    /// Common speeds stay one tap away beside the slider.
    static let presets: [Float] = [0.75, 1, 1.25, 1.5, 2]

    /// Rounds to the nearest step so slider drift, Siri and CarPlay values all land on the same grid.
    static func normalized(_ rate: Float) -> Float {
        guard rate.isFinite else { return 1 }
        let clamped = min(max(rate, range.lowerBound), range.upperBound)
        // Dividing whole twentieths gives the same Float as a literal such as 0.85.
        return (clamped * 20).rounded() / 20
    }

    static func stepped(_ rate: Float, by steps: Int) -> Float {
        normalized(normalized(rate) + Float(steps) * step)
    }

    static func matches(_ lhs: Float, _ rhs: Float) -> Bool {
        abs(lhs - rhs) < step / 2
    }

    static func label(_ rate: Float) -> String {
        let value = Double(normalized(rate))
        return value.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    static func accessibilityLabel(_ rate: Float) -> String {
        let value = Double(normalized(rate))
        return value.formatted(.number.precision(.fractionLength(0...2))) + " times"
    }
}
