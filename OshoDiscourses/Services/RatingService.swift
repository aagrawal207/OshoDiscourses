import Foundation
import Observation

@Observable
@MainActor
final class RatingService {
    static let shared = RatingService()

    private let defaults = UserDefaults.standard
    private let discoursePrefix = "rating.discourse."
    private let seriesPrefix = "rating.series."

    private init() {}

    func discourseRating(for id: String) -> Int {
        defaults.integer(forKey: discoursePrefix + id)
    }

    func setDiscourseRating(_ rating: Int, for id: String) {
        let clamped = max(0, min(rating, 5))
        if clamped == 0 {
            defaults.removeObject(forKey: discoursePrefix + id)
        } else {
            defaults.set(clamped, forKey: discoursePrefix + id)
        }
    }

    func seriesRating(for id: String) -> Int {
        defaults.integer(forKey: seriesPrefix + id)
    }

    func setSeriesRating(_ rating: Int, for id: String) {
        let clamped = max(0, min(rating, 5))
        if clamped == 0 {
            defaults.removeObject(forKey: seriesPrefix + id)
        } else {
            defaults.set(clamped, forKey: seriesPrefix + id)
        }
    }
}
