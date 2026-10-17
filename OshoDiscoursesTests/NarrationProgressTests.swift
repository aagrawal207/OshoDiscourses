import Foundation
import Testing
@testable import OshoDiscourses

struct NarrationProgressTests {
    @Test func progressIsWeightedBySourceLength() {
        var estimator = NarrationProgressEstimator(lengths: [100, 300, 600], completed: [], startedAt: 0)
        #expect(estimator.fraction == 0)
        estimator.complete(1, at: 5)
        #expect(estimator.fraction == 0.3)
        estimator.complete(1, at: 6)
        #expect(estimator.completedPassages == 1)
        estimator.complete(7, at: 6)
        #expect(estimator.fraction == 0.3)
        estimator.complete(0, at: 8)
        estimator.complete(2, at: 9)
        #expect(estimator.fraction == 1)
    }

    @Test func translatedPassagesCountAsHalfDoneUntilSpoken() {
        var estimator = NarrationProgressEstimator(lengths: [100, 300, 600], completed: [0], startedAt: 0)
        #expect(estimator.workFraction == 0.1)
        estimator.markTranslated([0, 1, 1, 9])
        #expect(estimator.workFraction == 0.25)
        estimator.complete(1, at: 5)
        #expect(estimator.workFraction == 0.4)
        #expect(estimator.fraction == 0.4)
        estimator.markTranslated([2])
        estimator.complete(2, at: 6)
        #expect(estimator.workFraction == 1)
    }

    @Test func estimateWaitsForTwoPassagesAndTenSeconds() {
        var estimator = NarrationProgressEstimator(lengths: [100, 100, 100, 100], completed: [], startedAt: 50)
        estimator.complete(0, at: 54)
        #expect(estimator.secondsRemaining == nil)
        estimator.complete(1, at: 58)
        #expect(estimator.secondsRemaining == nil)
        var slower = NarrationProgressEstimator(lengths: [100, 100, 100, 100], completed: [], startedAt: 50)
        slower.complete(0, at: 55)
        slower.complete(1, at: 60)
        #expect(slower.secondsRemaining == 10)
        slower.complete(2, at: 65)
        slower.complete(3, at: 70)
        #expect(slower.secondsRemaining == 0)
    }

    @Test func resumedPassagesCountTowardProgressButNotSpeed() {
        var estimator = NarrationProgressEstimator(lengths: [200, 200, 100, 100, 200], completed: [0, 1], startedAt: 0)
        #expect(estimator.fraction == 0.5)
        #expect(estimator.completedPassages == 2)
        estimator.complete(2, at: 10)
        estimator.complete(3, at: 20)
        #expect(estimator.secondsRemaining == 20)
    }

    @Test(arguments: [
        (0.0, "Less than a minute left"),
        (59.0, "Less than a minute left"),
        (60.0, "About 1 min left"),
        (61.0, "About 2 min left"),
        (540.0, "About 9 min left"),
        (3_540.0, "About 59 min left"),
        (3_600.0, "About 1 hr left"),
        (3_900.0, "About 1 hr 5 min left"),
        (Double.infinity, "Estimating time…"),
    ])
    func remainingTimeReadsNaturally(seconds: TimeInterval, text: String) {
        #expect(NarrationTimeFormatting.remaining(seconds) == text)
    }
}
