import Foundation
import Testing
@testable import OshoDiscourses

@MainActor
struct ScreenAwakeServiceTests {
    @Test func oneWindowCannotClearAnotherWindowsRequest() {
        var changes: [Bool] = []
        let service = ScreenAwakeService { changes.append($0) }
        let first = UUID()
        let second = UUID()
        service.setAwake(true, owner: first)
        service.setAwake(true, owner: second)
        service.setAwake(false, owner: first)
        #expect(changes == [true])
        service.setAwake(false, owner: second)
        #expect(changes == [true, false])
    }

    @Test func repeatedRequestsAndUnknownOwnersAreInert() {
        var changes: [Bool] = []
        let service = ScreenAwakeService { changes.append($0) }
        let owner = UUID()
        service.setAwake(false, owner: owner)
        service.setAwake(true, owner: owner)
        service.setAwake(true, owner: owner)
        service.setAwake(false, owner: UUID())
        service.setAwake(false, owner: owner)
        service.setAwake(false, owner: owner)
        #expect(changes == [true, false])
    }

    @Test func backgroundClearsRequestsAndForegroundCanReacquire() {
        var changes: [Bool] = []
        let service = ScreenAwakeService { changes.append($0) }
        let owner = UUID()
        service.setAwake(true, owner: owner)
        service.removeAllRequests()
        service.removeAllRequests()
        service.setAwake(true, owner: owner)
        service.setAwake(false, owner: owner)
        #expect(changes == [true, false, true, false])
    }
}
