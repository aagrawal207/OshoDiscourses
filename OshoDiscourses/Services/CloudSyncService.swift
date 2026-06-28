import Foundation

/// The slice of user data that syncs across a user's devices through their own
/// iCloud. Positions are bounded to recently-played discourses so the payload
/// stays small; `completed` is the full set (monotonic, merged by union).
/// Bookmarks and per-day listening seconds round out a full picture of "my
/// activity" so a second device or a reinstall keeps the streak and bookmarks.
struct CloudSnapshot: Codable, Equatable {
    var positions: [String: TimeInterval] = [:]
    var durations: [String: TimeInterval] = [:]
    var recentlyPlayed: [String] = []
    var completed: [String] = []
    var listenedCompleted: [String] = []
    var bookmarks: [Bookmark] = []
    /// Date string ("yyyy-MM-dd") → seconds listened that day. Merged by max per
    /// day so it converges idempotently (see ListeningStatsService.mergeSyncedStats).
    var dailyStats: [String: TimeInterval] = [:]
}

/// Mirrors listening progress through `NSUbiquitousKeyValueStore` (the user's
/// own iCloud — no account, no server). Sync is silent and best-effort: if the
/// user isn't signed into iCloud, reads return nil, merges no-op, and writes
/// stay in the local KVS cache. There is deliberately no user-facing toggle.
///
/// Conflict handling is done in `PlaybackStateService.mergeCloudSnapshot`, whose
/// rules (union of completed, max of positions, capped union of recency lists)
/// converge regardless of which device writes last, so we never need a merge UI
/// or a (fabricated) "last synced" timestamp.
@MainActor
final class CloudSyncService {
    static let shared = CloudSyncService()

    private let store = NSUbiquitousKeyValueStore.default
    private let snapshotKey = "cloud.progress.v1"
    private weak var playbackState: PlaybackStateService?
    private var observer: NSObjectProtocol?

    private init() {}

    /// Begin syncing the given playback state. Registers for external-change
    /// notifications and performs an initial reconcile (pull → merge → push).
    func start(playbackState: PlaybackStateService) {
        self.playbackState = playbackState
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] _ in
            // External change came from another device — merge it in, don't
            // immediately re-push (the other device already has its version).
            Task { @MainActor in self?.pull() }
        }
        store.synchronize()
        // Initial reconcile pushes our merged-up local state so local-only
        // progress propagates to other devices.
        pull(thenPush: true)
    }

    /// Read the cloud snapshot and merge it into local state. When `thenPush`
    /// is true, write the merged result back so local-only additions propagate.
    func pull(thenPush: Bool = false) {
        guard let playbackState else { return }
        if let data = store.data(forKey: snapshotKey),
           let snapshot = try? JSONDecoder().decode(CloudSnapshot.self, from: data) {
            // Playback progress (positions, completed, recency).
            playbackState.mergeCloudSnapshot(snapshot)
            // Bookmarks and listening stats live in their own singletons; merge
            // them with the same convergent, write-order-independent rules.
            BookmarkService.shared.mergeSyncedBookmarks(snapshot.bookmarks)
            ListeningStatsService.shared.mergeSyncedStats(snapshot.dailyStats)
        }
        if thenPush { push() }
    }

    /// Write the current local snapshot (progress + bookmarks + stats) to the cloud.
    func push() {
        guard let playbackState else { return }
        var snapshot = playbackState.exportCloudSnapshot()
        snapshot.bookmarks = BookmarkService.shared.bookmarks
        snapshot.dailyStats = ListeningStatsService.shared.syncedDailyStats()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        store.set(data, forKey: snapshotKey)
    }
}
