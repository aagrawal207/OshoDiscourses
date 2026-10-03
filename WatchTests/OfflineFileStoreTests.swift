import Foundation
import Testing
@testable import OshoDiscoursesWatch

struct OfflineFileStoreTests {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("OfflineStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private var storeDirectory: URL { root.appendingPathComponent("Offline") }

    private func incoming(_ name: String = "transfer.m4a", bytes: Int = 1_024) throws -> URL {
        let url = root.appendingPathComponent("inbox-\(UUID().uuidString)-\(name)")
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    private func metadata(_ id: String, resume: Double = 30, duration: Double = 600) throws -> Data {
        try CompanionWire.encode(CompanionOfflineFile(
            discourseID: id, title: "The Mustard Seed #3", series: "The Mustard Seed",
            resumePosition: resume, duration: duration
        ))
    }

    @Test func receiveMovesTheFileExcludesItFromBackupAndIndexesIt() throws {
        let store = OfflineFileStore(directory: storeDirectory)
        let source = try incoming()
        let entry = try store.receive(fileAt: source, metadata: metadata("mustard-seed-3"))
        #expect(!FileManager.default.fileExists(atPath: source.path), "The source is moved, not copied")
        let destination = store.fileURL(for: entry)
        #expect(destination.lastPathComponent == "mustard-seed-3.m4a")
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(try destination.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(try storeDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(entry.byteCount == 1_024)
        #expect(entry.position == 30)
        #expect(entry.startPosition == 30)
        #expect(store.inventory == ["mustard-seed-3"])
        #expect(store.totalBytes == 1_024)

        let reopened = OfflineFileStore(directory: storeDirectory)
        #expect(reopened.allEntries() == [entry])
    }

    @Test func missingOrBadMetadataIsRejected() throws {
        let store = OfflineFileStore(directory: storeDirectory)
        #expect(throws: OfflineStoreError.missingMetadata) { try store.receive(fileAt: try incoming(), metadata: nil) }
        #expect(throws: OfflineStoreError.missingMetadata) {
            try store.receive(fileAt: try incoming(), metadata: Data("x".utf8))
        }
        #expect(store.allEntries().isEmpty)
    }

    @Test func resendingReplacesAudioButKeepsLocalProgress() throws {
        let store = OfflineFileStore(directory: storeDirectory)
        try store.receive(fileAt: try incoming("a.mp3"), metadata: metadata("d1", resume: 10))
        store.updatePosition("d1", position: 250, finished: false)
        let again = try store.receive(fileAt: try incoming("b.m4a", bytes: 2_048), metadata: metadata("d1", resume: 5))
        #expect(again.position == 250)
        #expect(again.fileName == "d1.m4a")
        #expect(store.totalBytes == 2_048)
        let names = try FileManager.default.contentsOfDirectory(atPath: storeDirectory.path)
        #expect(!names.contains("d1.mp3"))
    }

    @Test func deleteRemovesFileAndEntry() throws {
        let store = OfflineFileStore(directory: storeDirectory)
        let entry = try store.receive(fileAt: try incoming(), metadata: metadata("d2"))
        store.delete("d2")
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: entry).path))
        #expect(OfflineFileStore(directory: storeDirectory).allEntries().isEmpty)
    }

    @Test func reopeningDropsEntriesWithoutAudioAndAudioWithoutEntries() throws {
        let store = OfflineFileStore(directory: storeDirectory)
        let kept = try store.receive(fileAt: try incoming(), metadata: metadata("kept"))
        let lost = try store.receive(fileAt: try incoming(), metadata: metadata("lost"))
        try FileManager.default.removeItem(at: store.fileURL(for: lost))
        try Data([1]).write(to: storeDirectory.appendingPathComponent("orphan.mp3"))
        let reopened = OfflineFileStore(directory: storeDirectory)
        #expect(reopened.inventory == ["kept"])
        #expect(FileManager.default.fileExists(atPath: reopened.fileURL(for: kept).path))
        #expect(!FileManager.default.fileExists(atPath: storeDirectory.appendingPathComponent("orphan.mp3").path))
    }

    @Test func idsAreSanitizedWithoutCollisions() {
        #expect(OfflineFileStore.sanitizedName("plain-id_1") == "plain-id_1")
        let a = OfflineFileStore.sanitizedName("../a/b")
        let b = OfflineFileStore.sanitizedName("../a?b")
        #expect(!a.contains("/"))
        #expect(!a.contains("."))
        #expect(a != b)
        #expect(OfflineFileStore.sanitizedName("") .hasPrefix("talk"))
    }

    @Test func arrivalSeedsTheStampAndAResendKeepsTheNewerListening() throws {
        let store = OfflineFileStore(directory: storeDirectory)
        let first = try store.receive(fileAt: try incoming(), file: Fixtures.offlineFile("d1", resume: 30, savedAt: Fixtures.t0))
        #expect(first.positionUpdatedAt == Fixtures.t0)
        store.updatePosition("d1", position: 250, finished: false, at: Fixtures.t0 + 100)

        // The phone's copy is older than the Watch's listening: the Watch keeps its own.
        let stale = try store.receive(fileAt: try incoming(), file: Fixtures.offlineFile("d1", resume: 90, savedAt: Fixtures.t0 + 50))
        #expect(stale.position == 250)
        #expect(stale.positionUpdatedAt == Fixtures.t0 + 100)

        // The phone listened since: its position and stamp win.
        let newer = try store.receive(fileAt: try incoming(), file: Fixtures.offlineFile("d1", resume: 400, savedAt: Fixtures.t0 + 200))
        #expect(newer.position == 400)
        #expect(newer.positionUpdatedAt == Fixtures.t0 + 200)

        // Never played anywhere on either side: the first arrival stands.
        try store.receive(fileAt: try incoming(), file: Fixtures.offlineFile("d2", resume: 0))
        let again = try store.receive(fileAt: try incoming(), file: Fixtures.offlineFile("d2", resume: 60))
        #expect(again.position == 0)
        #expect(again.positionUpdatedAt == nil)
    }

    @Test func newerPhoneListeningIsAdoptedAndPersisted() throws {
        let store = OfflineFileStore(directory: storeDirectory)
        try store.receive(fileAt: try incoming(), file: Fixtures.offlineFile("d1", resume: 40, duration: 5_400, savedAt: Fixtures.t0))
        let changed = store.adoptPhonePositions([Fixtures.saved("d1", 70 * 60, at: 3_600)], skipping: nil)
        #expect(changed == ["d1"])
        let entry = try #require(store.entry(for: "d1"))
        #expect(entry.position == 4_200)
        #expect(entry.startPosition == 4_200)
        #expect(entry.positionUpdatedAt == Fixtures.t0 + 3_600)
        #expect(OfflineFileStore(directory: storeDirectory).entry(for: "d1") == entry)
    }

    @Test func olderOrEqualPhoneListeningIsIgnored() throws {
        let store = OfflineFileStore(directory: storeDirectory)
        try store.receive(fileAt: try incoming(), file: Fixtures.offlineFile("d1", resume: 40, savedAt: Fixtures.t0))
        store.updatePosition("d1", position: 55, finished: false, at: Fixtures.t0 + 600)
        let changed = store.adoptPhonePositions(
            [Fixtures.saved("d1", 40, at: 0), Fixtures.saved("d1", 70, at: 600), Fixtures.saved("unknown", 9, at: 900)],
            skipping: nil
        )
        #expect(changed.isEmpty)
        #expect(store.entry(for: "d1")?.position == 55)
        #expect(store.entry(for: "d1")?.positionUpdatedAt == Fixtures.t0 + 600)
    }

    @Test func theLoadedTalkIsNeverMoved() throws {
        let store = OfflineFileStore(directory: storeDirectory)
        try store.receive(fileAt: try incoming(), file: Fixtures.offlineFile("loaded", resume: 40, savedAt: Fixtures.t0))
        try store.receive(fileAt: try incoming(), file: Fixtures.offlineFile("other", resume: 10, savedAt: Fixtures.t0))
        let changed = store.adoptPhonePositions(
            [Fixtures.saved("loaded", 300, at: 60), Fixtures.saved("other", 200, at: 60)], skipping: "loaded"
        )
        #expect(changed == ["other"])
        #expect(store.entry(for: "loaded")?.position == 40)
        #expect(store.entry(for: "loaded")?.positionUpdatedAt == Fixtures.t0)
    }

    @Test func aTalkFinishedOnThePhoneShowsFinishedAndStartsOver() throws {
        let store = OfflineFileStore(directory: storeDirectory)
        try store.receive(fileAt: try incoming(), file: Fixtures.offlineFile("d1", resume: 300, savedAt: Fixtures.t0))
        store.adoptPhonePositions([Fixtures.saved("d1", 0, at: 60, finished: true)], skipping: nil)
        let entry = try #require(store.entry(for: "d1"))
        #expect(entry.finished)
        #expect(entry.progress == 1)
        #expect(entry.startPosition == 0)
    }

    @Test func anIndexWrittenBeforeStampsDecodesAndThenPersistsThem() throws {
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: storeDirectory.appendingPathComponent("old.mp3"))
        let legacy = #"[{"discourseID":"old","title":"Old","series":"S","duration":600,"fileName":"old.mp3","#
            + #""byteCount":3,"addedAt":800000000,"position":120,"finished":false}]"#
        try Data(legacy.utf8).write(to: storeDirectory.appendingPathComponent(OfflineFileStore.indexFileName))

        let store = OfflineFileStore(directory: storeDirectory)
        let entry = try #require(store.entry(for: "old"))
        #expect(entry.position == 120)
        #expect(entry.positionUpdatedAt == nil)
        // No stamp counts as oldest, so any phone listening is newer.
        #expect(store.adoptPhonePositions([Fixtures.saved("old", 200, at: 0)], skipping: nil) == ["old"])
        #expect(OfflineFileStore(directory: storeDirectory).entry(for: "old")?.positionUpdatedAt == Fixtures.t0)
    }

    @Test func localSavesRestampOnlyWhenTheyMove() throws {
        let store = OfflineFileStore(directory: storeDirectory)
        try store.receive(fileAt: try incoming(), file: Fixtures.offlineFile("d1", resume: 30, savedAt: Fixtures.t0))
        #expect(!store.updatePosition("d1", position: 30.5, finished: false, at: Fixtures.t0 + 10))
        #expect(store.entry(for: "d1")?.positionUpdatedAt == Fixtures.t0)
        #expect(store.updatePosition("d1", position: 45, finished: false, at: Fixtures.t0 + 20))
        #expect(store.entry(for: "d1")?.positionUpdatedAt == Fixtures.t0 + 20)
        #expect(store.updatePosition("d1", position: 600, finished: true, at: Fixtures.t0 + 30))
        // Stopping at the end of a finished talk is not listening.
        #expect(!store.updatePosition("d1", position: 600, finished: false, at: Fixtures.t0 + 40))
        #expect(store.entry(for: "d1")?.finished == true)
        #expect(store.updatePosition("d1", position: 12, finished: false, at: Fixtures.t0 + 50))
        #expect(store.entry(for: "d1")?.finished == false)
        #expect(store.entry(for: "d1")?.positionUpdatedAt == Fixtures.t0 + 50)
    }

    @Test func finishedOrNearlyFinishedTalksStartOver() {
        var entry = OfflineEntry(discourseID: "d", title: "t", series: "s", duration: 600, fileName: "d.mp3",
                                 byteCount: 1, addedAt: Date(), position: 597, finished: false)
        #expect(entry.startPosition == 0)
        entry.position = 300
        #expect(entry.startPosition == 300)
        #expect(entry.progress == 0.5)
        entry.finished = true
        #expect(entry.startPosition == 0)
        #expect(entry.progress == 1)
    }
}
