import Testing
import Foundation
@testable import OshoDiscourses

/// Convergent-merge rules for the data added to iCloud sync: bookmarks (union by
/// id) and daily listening stats (max seconds per day). Like the playback merge
/// rules, these must converge regardless of write order and be idempotent so a
/// device re-syncing its own data changes nothing.
@Suite(.serialized)
@MainActor
struct SyncMergeTests {

    // MARK: - Bookmarks (union by id)

    @Test func bookmarkMergeUnionsDistinctEntries() {
        let local = [Bookmark(discourseID: "d1", seriesName: "S", title: "A", timestamp: 10)]
        let incoming = [Bookmark(discourseID: "d2", seriesName: "S", title: "B", timestamp: 20)]
        let merged = BookmarkService.mergeBookmarks(local: local, incoming: incoming)
        #expect(merged.count == 2)
    }

    @Test func bookmarkMergeDeduplicatesByID() {
        let shared = Bookmark(discourseID: "d1", seriesName: "S", title: "A", timestamp: 10)
        // Same id present on both sides must collapse to one.
        let merged = BookmarkService.mergeBookmarks(local: [shared], incoming: [shared])
        #expect(merged.count == 1)
        #expect(merged.first?.id == shared.id)
    }

    @Test func bookmarkMergeIsIdempotent() {
        let a = Bookmark(discourseID: "d1", seriesName: "S", title: "A", timestamp: 10)
        let b = Bookmark(discourseID: "d2", seriesName: "S", title: "B", timestamp: 20)
        let once = BookmarkService.mergeBookmarks(local: [a, b], incoming: [a])
        let twice = BookmarkService.mergeBookmarks(local: once, incoming: [a, b])
        #expect(Set(once.map(\.id)) == Set(twice.map(\.id)))
        #expect(twice.count == 2)
    }

    @Test func bookmarkMergeSortsNewestFirst() {
        // createdAt is stamped at init; create in order so the second is newer.
        let older = Bookmark(discourseID: "d1", seriesName: "S", title: "Older", timestamp: 10)
        let newer = Bookmark(discourseID: "d2", seriesName: "S", title: "Newer", timestamp: 20)
        // Feed them in the "wrong" order to prove the sort, not the input order.
        let merged = BookmarkService.mergeBookmarks(local: [older], incoming: [newer])
        #expect(merged.first?.createdAt ?? .distantPast >= merged.last?.createdAt ?? .distantFuture)
    }

    // MARK: - Daily stats (max per day)

    @Test func statsMergeAddsMissingDays() {
        let stats = ListeningStatsService.shared
        let unique = "2000-01-01"  // a day far from any real usage
        let before = stats.syncedDailyStats()[unique] ?? 0
        let changed = stats.mergeSyncedStats([unique: before + 123])
        #expect(changed == true)
        #expect(stats.syncedDailyStats()[unique] == before + 123)
        // Re-merging the same value is a no-op (idempotent / max wins).
        #expect(stats.mergeSyncedStats([unique: before + 123]) == false)
    }

    @Test func statsMergeKeepsLargerValue() {
        let stats = ListeningStatsService.shared
        let day = "2000-01-02"
        stats.mergeSyncedStats([day: 500])
        // A smaller incoming value must not lower the local total.
        let changed = stats.mergeSyncedStats([day: 100])
        #expect(changed == false)
        #expect(stats.syncedDailyStats()[day] == 500)
        // A larger one wins.
        #expect(stats.mergeSyncedStats([day: 900]) == true)
        #expect(stats.syncedDailyStats()[day] == 900)
    }

    // MARK: - Snapshot round-trip with the new fields

    @Test func snapshotEncodesBookmarksAndStats() throws {
        var snapshot = CloudSnapshot()
        snapshot.bookmarks = [Bookmark(discourseID: "d1", seriesName: "S", title: "A", timestamp: 5)]
        snapshot.dailyStats = ["2024-01-01": 600]

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(CloudSnapshot.self, from: data)
        #expect(decoded.bookmarks.count == 1)
        #expect(decoded.bookmarks.first?.discourseID == "d1")
        #expect(decoded.dailyStats["2024-01-01"] == 600)
    }
}
