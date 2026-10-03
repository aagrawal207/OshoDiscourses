#if canImport(CarPlay) && !targetEnvironment(macCatalyst)
import CarPlay
import Foundation
import MediaPlayer
import Testing
@testable import OshoDiscourses

extension CarPlayTests {
    @MainActor
    @Suite struct Session {
        private func playableSource() -> FakeCarPlaySource {
            let source = FakeCarPlaySource()
            source.pages[.continueListening] = [CarPlayFixture.discourse("d1"), CarPlayFixture.discourse("d2")]
            source.pages[.bookmarks] = [CarPlayFixture.bookmark("b1")]
            source.pages[.downloads] = [CarPlayFixture.series("s1", title: "The Mustard Seed")]
            source.pages[.series("s1")] = [CarPlayFixture.discourse("s1-1"), CarPlayFixture.discourse("s1-2")]
            return source
        }

        @Test func selectingADiscoursePlaysItThenShowsNowPlayingOnce() throws {
            let source = playableSource()
            let interface = CarPlayTestInterface()
            let session = CarPlayFixture.session(source, interface: interface)
            defer { session.disconnect() }
            let rows = CarPlayFixture.rows(try CarPlayFixture.rootList(session, 0))
            try CarPlayFixture.select(rows[0])
            #expect(source.played == ["d:d1"])
            #expect(interface.topTemplate === CPNowPlayingTemplate.shared)
            #expect(session.lastSelectionOutcome == .played)
            // The list row's handler stays valid while Now Playing covers it.
            try CarPlayFixture.select(rows[1])
            #expect(source.played == ["d:d1", "d:d2"])
            #expect(interface.pushed.filter { $0 === CPNowPlayingTemplate.shared }.count == 1)
            #expect(interface.templates.filter { $0 === CPNowPlayingTemplate.shared }.count == 1)
        }

        @Test func selectingABookmarkUsesTheBookmarkRowID() throws {
            let source = playableSource()
            let interface = CarPlayTestInterface()
            let session = CarPlayFixture.session(source, interface: interface)
            defer { session.disconnect() }
            try interface.selectTab(at: 2)
            try CarPlayFixture.select(try #require(CarPlayFixture.rows(try CarPlayFixture.rootList(session, 2)).first))
            #expect(source.played == ["b:b1"])
            #expect(interface.topTemplate === CPNowPlayingTemplate.shared)
        }

        @Test func overlappingSelectionsSubmitOnePushWhileTheFirstIsInFlight() throws {
            let source = playableSource()
            let interface = CarPlayTestInterface()
            let session = CarPlayFixture.session(source, interface: interface)
            defer { session.disconnect() }
            interface.automaticallyCompletes = false
            let rows = CarPlayFixture.rows(try CarPlayFixture.rootList(session, 0))
            try CarPlayFixture.select(rows[0])
            try CarPlayFixture.select(rows[1])
            #expect(source.played == ["d:d1", "d:d2"])
            #expect(interface.pendingCount == 1)
            try interface.completeNext()
            #expect(interface.pendingCount == 0)
            #expect(interface.pushed.count == 1)
            #expect(interface.topTemplate === CPNowPlayingTemplate.shared)
        }

        @Test func nowPlayingAlreadyInTheStackIsPoppedToNotPushedAgain() async throws {
            let source = playableSource()
            source.currentDiscourseID = "d1"
            source.queue = [CarPlayQueueEntry(discourseID: "d1", title: "One", series: "S"),
                            CarPlayQueueEntry(discourseID: "d2", title: "Two", series: "S")]
            let interface = CarPlayTestInterface()
            let session = CarPlayFixture.session(source, interface: interface)
            defer { session.disconnect() }
            try CarPlayFixture.select(CarPlayFixture.rows(try CarPlayFixture.rootList(session, 0))[0])
            let controls = try #require(session.nowPlayingControls)
            controls.nowPlayingTemplateUpNextButtonTapped(CPNowPlayingTemplate.shared)
            await CarPlayFixture.settle()
            let upNext = try #require(interface.topTemplate as? CPListTemplate)
            #expect(upNext.title == "Up Next")
            let entries = CarPlayFixture.rows(upNext)
            #expect(entries.map(\.text) == ["One", "Two"])
            #expect(entries[0].isPlaying)
            try CarPlayFixture.select(entries[1])
            #expect(source.playedQueueIndices == [1])
            #expect(interface.operations.last == .pop)
            #expect(interface.topTemplate === CPNowPlayingTemplate.shared)
            #expect(interface.pushed.filter { $0 === CPNowPlayingTemplate.shared }.count == 1)
        }

        @Test func seriesRowsOpenTheSeriesDownloads() throws {
            let source = playableSource()
            let interface = CarPlayTestInterface()
            let session = CarPlayFixture.session(source, interface: interface)
            defer { session.disconnect() }
            try interface.selectTab(at: 1)
            try CarPlayFixture.select(try #require(CarPlayFixture.rows(try CarPlayFixture.rootList(session, 1)).first))
            let series = try #require(interface.topTemplate as? CPListTemplate)
            #expect(series.title == "The Mustard Seed")
            #expect(CarPlayFixture.rows(series).map(\.text) == ["Talk s1-1", "Talk s1-2"])
            #expect(session.lastSelectionOutcome == .opened)
            try CarPlayFixture.select(CarPlayFixture.rows(series)[1])
            #expect(source.played == ["d:s1-2"])
            #expect(interface.templates.count == 3)
        }

        @Test func launcherFailurePresentsItsMessageAndDoesNotNavigate() throws {
            let source = playableSource()
            source.failures["d:d1"] = .notDownloaded
            let interface = CarPlayTestInterface()
            let session = CarPlayFixture.session(source, interface: interface)
            defer { session.disconnect() }
            try CarPlayFixture.select(CarPlayFixture.rows(try CarPlayFixture.rootList(session, 0))[0])
            #expect(source.played.isEmpty)
            let alert = try #require(interface.presented.last as? CPAlertTemplate)
            #expect(alert.titleVariants == [PlaybackLauncher.Failure.notDownloaded.message])
            #expect(session.lastSelectionOutcome == .failed)
            #expect(interface.pushed.isEmpty)
            // A second failure replaces the first alert instead of stacking.
            try CarPlayFixture.select(CarPlayFixture.rows(try CarPlayFixture.rootList(session, 0))[0])
            #expect(Array(interface.operations.suffix(2)) == [.dismiss, .present])
        }

        @Test func aRowRemovedByARefreshIsRejectedAsStale() throws {
            let source = playableSource()
            let interface = CarPlayTestInterface()
            let session = CarPlayFixture.session(source, interface: interface)
            defer { session.disconnect() }
            let list = try CarPlayFixture.rootList(session, 0)
            let old = CarPlayFixture.rows(list)
            source.pages[.continueListening] = [CarPlayFixture.discourse("d2")]
            session.refresh()
            #expect(CarPlayFixture.rows(list).map(\.text) == ["Talk d2"])
            try CarPlayFixture.select(old[0])
            #expect(source.played.isEmpty)
            #expect(session.lastSelectionOutcome == .stale)
            #expect(interface.pushed.isEmpty)
            // The surviving id still plays even from the replaced row object.
            try CarPlayFixture.select(old[1])
            #expect(source.played == ["d:d2"])
        }

        @Test func progressRefreshUpdatesRowsInPlace() throws {
            let source = playableSource()
            let session = CarPlayFixture.session(source, interface: CarPlayTestInterface())
            defer { session.disconnect() }
            let list = try CarPlayFixture.rootList(session, 0)
            let before = CarPlayFixture.rows(list)
            source.pages[.continueListening] = [CarPlayFixture.discourse("d1", progress: 0.5, current: true),
                                                CarPlayFixture.discourse("d2")]
            session.refreshVisibleList()
            let after = CarPlayFixture.rows(list)
            #expect(after[0] === before[0])
            #expect(abs(after[0].playbackProgress - 0.5) < 0.0001)
            #expect(after[0].isPlaying)
            try CarPlayFixture.select(after[0])
            #expect(source.played == ["d:d1"])
        }

        @Test func serviceChangesRefreshTheListsOnce() async throws {
            let source = playableSource()
            let session = CarPlayFixture.session(source, interface: CarPlayTestInterface())
            defer { session.disconnect() }
            let list = try CarPlayFixture.rootList(session, 2)
            source.pages[.bookmarks] = [CarPlayFixture.bookmark("b1"), CarPlayFixture.bookmark("b2")]
            let requests = source.pageRequests.count
            source.fireChange()
            source.fireChange()
            await CarPlayFixture.settle()
            #expect(CarPlayFixture.rows(list).count == 2)
            // Coalesced: one refresh of the three root lists, not two.
            #expect(source.pageRequests.count - requests == 3)
        }

        @Test func progressTimerRefreshesOnlyWhilePlaying() async throws {
            let source = playableSource()
            let session = CarPlayFixture.session(source, interface: CarPlayTestInterface(), progress: .milliseconds(20))
            defer { session.disconnect() }
            let requests = source.pageRequests.count
            try await Task.sleep(for: .milliseconds(120))
            #expect(source.pageRequests.count == requests)
            source.isPlaying = true
            try await Task.sleep(for: .milliseconds(120))
            #expect(source.pageRequests.count > requests)
            #expect(Set(source.pageRequests.dropFirst(requests)) == [.continueListening])
        }

        @Test func disconnectCancelsCarPlayWorkWithoutTouchingPlayback() async throws {
            let source = playableSource()
            source.currentDiscourseID = "d1"
            let interface = CarPlayTestInterface()
            let session = CarPlayFixture.session(source, interface: interface, progress: .milliseconds(10))
            let rows = CarPlayFixture.rows(try CarPlayFixture.rootList(session, 0))
            let center = MPNowPlayingInfoCenter.default()
            let previous = center.nowPlayingInfo
            defer { center.nowPlayingInfo = previous }
            center.nowPlayingInfo = [MPMediaItemPropertyTitle: "Sentinel"]
            let controls = try #require(session.nowPlayingControls)
            let tabs = try #require(session.rootTemplate as? CPTabBarTemplate)

            session.disconnect()

            #expect(!session.isConnected)
            #expect(interface.delegate == nil)
            #expect(tabs.delegate == nil)
            let allCancelled = source.observations.allSatisfy { $0.isCancelled }
            #expect(allCancelled)
            #expect(!controls.isConnected)
            #expect(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Sentinel")
            try CarPlayFixture.select(rows[0])
            #expect(source.played.isEmpty)
            source.isPlaying = true
            let requests = source.pageRequests.count
            try await Task.sleep(for: .milliseconds(60))
            #expect(source.pageRequests.count == requests)
            #expect(controls.activateBookmark() == .nothingPlaying)
            #expect(source.bookmarksAdded == 0)
        }

        @Test func lateCompletionFromAnEndedConnectionIsIgnored() throws {
            let source = playableSource()
            let interface = CarPlayTestInterface()
            let session = CarPlayFixture.session(source, interface: interface)
            interface.automaticallyCompletes = false
            try CarPlayFixture.select(CarPlayFixture.rows(try CarPlayFixture.rootList(session, 0))[0])
            session.disconnect()
            try interface.completeNext(success: false, message: "late")
            #expect(interface.presented.isEmpty)
        }

        @Test func reconnectBuildsAFreshRoot() throws {
            let source = playableSource()
            let interface = CarPlayTestInterface()
            let session = CarPlayFixture.session(source, interface: interface)
            defer { session.disconnect() }
            let first = try #require(session.rootTemplate)
            let oldRow = CarPlayFixture.rows(try CarPlayFixture.rootList(session, 0))[0]
            session.connect()
            #expect(session.rootTemplate !== first)
            #expect(interface.operations.filter { $0 == .root }.count == 2)
            try CarPlayFixture.select(oldRow)
            #expect(source.played.isEmpty)
        }

        @Test func rateButtonStepsTheSpeed() throws {
            let source = playableSource()
            source.currentDiscourseID = "d1"
            source.playbackRate = 1.5
            let session = CarPlayFixture.session(source, interface: CarPlayTestInterface())
            defer { session.disconnect() }
            let controls = try #require(session.nowPlayingControls)
            controls.activateRate()
            controls.activateRate()
            #expect(source.rates == [1.75, 2])
        }

        @Test func bookmarkButtonAddsOneBookmarkPerTapBurst() throws {
            let source = playableSource()
            let clock = TestClock()
            let controls = CarPlayNowPlayingControls(source: source, upNext: {}, now: { clock.now })
            defer { controls.disconnect() }
            #expect(controls.activateBookmark() == .nothingPlaying)
            source.currentDiscourseID = "d1"
            #expect(controls.activateBookmark() == .added)
            #expect(controls.isShowingBookmarkConfirmation)
            let button = try #require(CPNowPlayingTemplate.shared.nowPlayingButtons.last as? CPNowPlayingImageButton)
            #expect(button.isSelected)
            clock.now += 1
            #expect(controls.activateBookmark() == .repeated)
            clock.now += CarPlayNowPlayingControls.bookmarkRepeatWindow
            #expect(controls.activateBookmark() == .added)
            source.currentDiscourseID = "d2"
            #expect(controls.activateBookmark() == .added)
            #expect(source.bookmarksAdded == 3)
            controls.update()
            #expect(controls.isShowingBookmarkConfirmation)
            source.currentDiscourseID = "d3"
            controls.update()
            #expect(!controls.isShowingBookmarkConfirmation)
        }
    }
}

@MainActor
final class TestClock {
    var now = Date(timeIntervalSince1970: 1_000_000)
}
#endif
