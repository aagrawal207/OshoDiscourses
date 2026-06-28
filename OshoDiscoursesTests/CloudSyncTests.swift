import Testing
import Foundation
@testable import OshoDiscourses

/// Tests for the conflict-free merge rules that back iCloud sync. The pure
/// `mergeList` helper and the snapshot export/merge round-trips matter most —
/// they're the contract that two devices converge to the same state regardless
/// of write order.
@Suite(.serialized)
@MainActor
struct CloudSyncTests {

    private func makeFreshService() -> PlaybackStateService {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("playbackPosition_") || key.hasPrefix("playbackDuration_") {
            defaults.removeObject(forKey: key)
        }
        defaults.removeObject(forKey: "recentlyPlayed")
        defaults.removeObject(forKey: "completedDiscourseIDs")
        defaults.removeObject(forKey: "listenedCompletedIDs")
        return PlaybackStateService()
    }

    // MARK: - mergeList

    @Test func mergeListPutsCloudFirstThenLocal() {
        let merged = PlaybackStateService.mergeList(cloud: ["a", "b"], local: ["c", "d"], cap: 10)
        #expect(merged == ["a", "b", "c", "d"])
    }

    @Test func mergeListDeduplicatesKeepingCloudPosition() {
        let merged = PlaybackStateService.mergeList(cloud: ["a", "b"], local: ["b", "c"], cap: 10)
        #expect(merged == ["a", "b", "c"])
    }

    @Test func mergeListRespectsCap() {
        let merged = PlaybackStateService.mergeList(cloud: ["a", "b", "c"], local: ["d", "e"], cap: 3)
        #expect(merged == ["a", "b", "c"])
    }

    @Test func mergeListHandlesEmpty() {
        #expect(PlaybackStateService.mergeList(cloud: [], local: ["x"], cap: 5) == ["x"])
        #expect(PlaybackStateService.mergeList(cloud: ["y"], local: [], cap: 5) == ["y"])
        #expect(PlaybackStateService.mergeList(cloud: [], local: [], cap: 5) == [])
    }

    // MARK: - Position merge (max wins)

    @Test func mergeKeepsFartherPositionFromCloud() {
        let service = makeFreshService()
        service.savePosition(discourseId: "d-1", position: 30, duration: 600)
        service.recordPlay(discourseId: "d-1")

        var snapshot = CloudSnapshot()
        snapshot.positions = ["d-1": 120]
        snapshot.durations = ["d-1": 600]
        service.mergeCloudSnapshot(snapshot)

        #expect(service.getPosition(discourseId: "d-1") == 120)
    }

    @Test func mergeDoesNotRewindLocalAheadOfCloud() {
        let service = makeFreshService()
        service.savePosition(discourseId: "d-1", position: 200, duration: 600)
        service.recordPlay(discourseId: "d-1")

        var snapshot = CloudSnapshot()
        snapshot.positions = ["d-1": 50]
        service.mergeCloudSnapshot(snapshot)

        #expect(service.getPosition(discourseId: "d-1") == 200)
    }

    // MARK: - Completed union

    @Test func mergeUnionsCompletedSet() {
        let service = makeFreshService()
        service.markCompleted(discourseId: "local-1")

        var snapshot = CloudSnapshot()
        snapshot.completed = ["cloud-1", "cloud-2"]
        service.mergeCloudSnapshot(snapshot)

        #expect(service.isCompleted("local-1"))
        #expect(service.isCompleted("cloud-1"))
        #expect(service.isCompleted("cloud-2"))
    }

    // MARK: - Export/merge round-trip

    @Test func exportSnapshotIncludesRecentPositions() {
        let service = makeFreshService()
        service.recordPlay(discourseId: "d-1")
        service.savePosition(discourseId: "d-1", position: 42, duration: 300)

        let snapshot = service.exportCloudSnapshot()
        #expect(snapshot.recentlyPlayed.contains("d-1"))
        #expect(snapshot.positions["d-1"] == 42)
        #expect(snapshot.durations["d-1"] == 300)
    }

    @Test func mergeIsIdempotent() {
        let service = makeFreshService()
        service.recordPlay(discourseId: "d-1")
        service.savePosition(discourseId: "d-1", position: 90, duration: 300)
        service.markCompleted(discourseId: "c-1")

        let snapshot = service.exportCloudSnapshot()
        // Merging our own exported snapshot back in must change nothing.
        let changed = service.mergeCloudSnapshot(snapshot)
        #expect(changed == false)
    }

    @Test func mergeReportsChangeWhenCloudHasNewData() {
        let service = makeFreshService()
        var snapshot = CloudSnapshot()
        snapshot.completed = ["new-1"]
        #expect(service.mergeCloudSnapshot(snapshot) == true)
    }

    @Test func snapshotCodableRoundTrip() throws {
        var snapshot = CloudSnapshot()
        snapshot.positions = ["a": 1.5]
        snapshot.durations = ["a": 60]
        snapshot.recentlyPlayed = ["a", "b"]
        snapshot.completed = ["c"]
        snapshot.listenedCompleted = ["d"]

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(CloudSnapshot.self, from: data)
        #expect(decoded == snapshot)
    }
}
