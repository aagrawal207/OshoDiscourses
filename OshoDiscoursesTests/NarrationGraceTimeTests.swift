import Foundation
import Testing
@testable import OshoDiscourses

@MainActor
struct NarrationGraceTimeTests {
    @Test func expiryEndsTheTaskBeforeTellingTheServiceAndOnlyOnce() {
        let system = GraceSystem()
        let grace = system.make()
        var statuses: [NarrationBackgroundStatus] = []
        var expiries = 0
        grace.begin(title: "Title", subtitle: "Start", onStatusChange: { statuses.append($0) }, onExpire: {
            #expect(system.ended == [1])
            expiries += 1
        })
        #expect(statuses == [.running])
        system.expire?()
        system.expire?()
        #expect(expiries == 1)
        grace.end(success: true)
        #expect(system.ended == [1])
    }

    @Test func aNewRunReplacesTheOldTaskAndIgnoresItsLateExpiry() {
        let system = GraceSystem()
        let grace = system.make()
        var expiries = 0
        grace.begin(title: "Old", subtitle: "", onStatusChange: { _ in }, onExpire: { expiries += 1 })
        let oldExpiry = system.expire
        grace.begin(title: "New", subtitle: "", onStatusChange: { _ in }, onExpire: { expiries += 1 })
        #expect(system.ended == [1])
        oldExpiry?()
        #expect(expiries == 0)
        grace.end(success: true)
        #expect(system.ended == [1, 2])
    }

    @Test func refusedGraceTimeIsReportedUnavailable() {
        let system = GraceSystem()
        system.refuses = true
        let grace = system.make()
        var statuses: [NarrationBackgroundStatus] = []
        grace.begin(title: "Title", subtitle: "", onStatusChange: { statuses.append($0) }, onExpire: {})
        #expect(statuses == [.unavailable(.notPermitted)])
        grace.end(success: false)
        #expect(system.ended.isEmpty)
    }
}

@MainActor
private final class GraceSystem {
    var refuses = false
    var next = 0
    var ended: [Int] = []
    var expire: (@MainActor () -> Void)?

    func make() -> NarrationGraceTime {
        NarrationGraceTime(
            begin: { [unowned self] expire in
                guard !refuses else { return nil }
                next += 1
                self.expire = expire
                return next
            },
            end: { [unowned self] in ended.append($0) }
        )
    }
}
