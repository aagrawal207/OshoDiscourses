#if canImport(CarPlay) && !targetEnvironment(macCatalyst)
import Foundation
import Testing
@testable import OshoDiscourses

extension CarPlayTests {
    /// The app's adapter over real `CompanionLibrary` and `PlaybackLauncher`,
    /// with a silent player and isolated playback defaults.
    @MainActor
    @Suite struct RuntimeSource {
        private struct Fixture {
            let player: AudioPlayerService
            let downloads: DownloadService
            let playbackState: PlaybackStateService
            let source: CarPlayRuntimeSource
        }

        private func makeFixture() -> Fixture {
            let suite = "CarPlayRuntimeSourceTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            let player = AudioPlayerService(settings: nil, connectsToSystem: false)
            let downloads = DownloadService()
            let playbackState = PlaybackStateService(defaults: defaults, recordListeningTime: { _ in }, saveListeningStats: {})
            let library = CompanionLibrary(downloads: downloads, playbackState: playbackState, bookmarks: .shared, player: player)
            let launcher = PlaybackLauncher(player: player, downloads: downloads, bookmarks: .shared)
            let source = CarPlayRuntimeSource(library: library, launcher: launcher, player: player, downloads: downloads,
                                              playbackState: playbackState, bookmarks: .shared)
            return Fixture(player: player, downloads: downloads, playbackState: playbackState, source: source)
        }

        private func expectFailure(_ expected: PlaybackLauncher.Failure, playing rowID: String, on source: CarPlayRuntimeSource) {
            do {
                try source.play(rowID: rowID)
                Issue.record("Expected \(expected) for \(rowID)")
            } catch {
                #expect(error == expected)
            }
        }

        @Test func unplayableRowsReportTheLauncherFailure() throws {
            let fixture = makeFixture()
            let source = fixture.source
            expectFailure(.unknownDiscourse, playing: CompanionLibrary.rowID(discourse: "no-such-talk"), on: source)
            expectFailure(.unknownDiscourse, playing: CompanionLibrary.rowID(series: "any"), on: source)
            expectFailure(.unknownDiscourse, playing: "garbage", on: source)
            expectFailure(.unknownBookmark, playing: CompanionLibrary.rowID(bookmark: UUID().uuidString), on: source)
            let notDownloaded = try #require(Catalog.allDiscourses().first { !fixture.downloads.isDownloaded($0.id) })
            expectFailure(.notDownloaded, playing: CompanionLibrary.rowID(discourse: notDownloaded.id), on: source)
            #expect(fixture.player.currentTrackId == nil)
            #expect(!source.addBookmarkAtCurrentTime())
        }

        @Test func pagesComeFromTheCompanionLibraryWithinTheRowBound() {
            let fixture = makeFixture()
            let page = fixture.source.page(for: .downloads, maximumRows: 3)
            #expect(page.location == .downloads)
            #expect(page.rows.count <= 3)
            #expect(fixture.source.page(for: .continueListening, maximumRows: 10).rows.isEmpty)
        }

        @Test func observationFiresForListStateButNotPositionTicks() async throws {
            let fixture = makeFixture()
            let fired = CompletionCount()
            let token = fixture.source.observeChanges { fired.value += 1 }
            defer { token.cancel() }
            fixture.player.currentTime = 42
            await CarPlayFixture.settle()
            #expect(fired.value == 0)
            fixture.playbackState.recordPlay(discourseId: "carplay-observed")
            await CarPlayFixture.settle()
            #expect(fired.value == 1)
            // Re-armed after each change.
            fixture.player.setRate(1.5)
            await CarPlayFixture.settle()
            #expect(fired.value == 2)
            token.cancel()
            fixture.player.setRate(1.25)
            await CarPlayFixture.settle()
            #expect(fired.value == 2)
        }

        @Test func queueAndRateReflectThePlayer() {
            let fixture = makeFixture()
            #expect(fixture.source.queue.isEmpty)
            #expect(fixture.source.currentDiscourseID == nil)
            fixture.source.setRate(1.75)
            #expect(fixture.source.playbackRate == 1.75)
            #expect(fixture.player.playbackRate == 1.75)
        }
    }
}
#endif
