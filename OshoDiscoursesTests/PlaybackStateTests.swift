import Testing
import Foundation
@testable import OshoDiscourses

@Suite(.serialized)
@MainActor
struct PlaybackStateTests {

    private func makeFreshService() -> PlaybackStateService {
        let service = PlaybackStateService()
        // Clear any leftover state
        let defaults = UserDefaults.standard
        let allKeys = defaults.dictionaryRepresentation().keys
        for key in allKeys where key.hasPrefix("playbackPosition_") {
            defaults.removeObject(forKey: key)
        }
        defaults.removeObject(forKey: "recentlyPlayed")
        return PlaybackStateService()
    }

    @Test func recordPlayAddsToRecent() {
        let service = makeFreshService()
        service.recordPlay(discourseId: "test-1")
        #expect(service.recentlyPlayed.contains("test-1"))
    }

    @Test func recordPlayPutsNewestFirst() {
        let service = makeFreshService()
        service.recordPlay(discourseId: "test-1")
        service.recordPlay(discourseId: "test-2")
        #expect(service.recentlyPlayed.first == "test-2")
    }

    @Test func recordPlayDeduplicates() {
        let service = makeFreshService()
        service.recordPlay(discourseId: "test-1")
        service.recordPlay(discourseId: "test-2")
        service.recordPlay(discourseId: "test-1")
        let count = service.recentlyPlayed.filter { $0 == "test-1" }.count
        #expect(count == 1)
        #expect(service.recentlyPlayed.first == "test-1")
    }

    @Test func saveAndGetPosition() {
        let service = makeFreshService()
        service.savePosition(discourseId: "test-1", position: 123.5)
        let pos = service.getPosition(discourseId: "test-1")
        #expect(pos == 123.5)
    }

    @Test func clearPositionRemovesPositionAndRecent() {
        let service = makeFreshService()
        service.recordPlay(discourseId: "test-1")
        service.savePosition(discourseId: "test-1", position: 60.0)

        service.clearPosition(discourseId: "test-1")

        #expect(service.getPosition(discourseId: "test-1") == 0)
        #expect(!service.recentlyPlayed.contains("test-1"))
    }

    @Test func dismissFromRecentKeepsPosition() {
        let service = makeFreshService()
        service.recordPlay(discourseId: "test-1")
        service.savePosition(discourseId: "test-1", position: 45.0)

        service.dismissFromRecent(discourseId: "test-1")

        #expect(service.getPosition(discourseId: "test-1") == 45.0)
        #expect(!service.recentlyPlayed.contains("test-1"))
    }

    @Test func dismissDoesNotAffectOtherItems() {
        let service = makeFreshService()
        service.recordPlay(discourseId: "test-1")
        service.recordPlay(discourseId: "test-2")
        service.savePosition(discourseId: "test-1", position: 30.0)
        service.savePosition(discourseId: "test-2", position: 60.0)

        service.dismissFromRecent(discourseId: "test-1")

        #expect(service.recentlyPlayed.contains("test-2"))
        #expect(service.getPosition(discourseId: "test-2") == 60.0)
    }

    @Test func recentlyPlayedCapsAt20() {
        let service = makeFreshService()
        for i in 1...25 {
            service.recordPlay(discourseId: "item-\(i)")
        }
        #expect(service.recentlyPlayed.count == 20)
        #expect(service.recentlyPlayed.first == "item-25")
    }

    @Test func zeroPositionNotSaved() {
        let service = makeFreshService()
        service.savePosition(discourseId: "test-1", position: 0)
        #expect(service.getPosition(discourseId: "test-1") == 0)
    }
}
