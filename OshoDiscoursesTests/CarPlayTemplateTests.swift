#if canImport(CarPlay) && !targetEnvironment(macCatalyst)
import CarPlay
import Foundation
import Testing
@testable import OshoDiscourses

extension CarPlayTests {
    @MainActor
    @Suite struct Templates {
        @Test func rootHasThreeTabsWithTitlesAndSymbols() throws {
            let source = FakeCarPlaySource()
            let interface = CarPlayTestInterface()
            let session = CarPlayFixture.session(source, interface: interface)
            defer { session.disconnect() }
            let tabs = try #require(session.rootTemplate as? CPTabBarTemplate)
            #expect(tabs.templates.count == 3)
            #expect(tabs.templates.map(\.tabTitle) == ["Continue Listening", "Downloads", "Bookmarks"])
            #expect(tabs.templates.allSatisfy { $0.tabImage != nil })
            #expect(interface.operations == [.root])
            #expect(interface.root === tabs)
            #expect(Set(source.pageRequests) == [.continueListening, .downloads, .bookmarks])
        }

        @Test func upNextKeepsThePlayingDiscourseInView() {
            #expect(CarPlayListTemplates.queueWindow(count: 3, current: 1, limit: 12) == 0..<3)
            #expect(CarPlayListTemplates.queueWindow(count: 100, current: 0, limit: 12) == 0..<12)
            #expect(CarPlayListTemplates.queueWindow(count: 100, current: 50, limit: 12) == 49..<61)
            #expect(CarPlayListTemplates.queueWindow(count: 100, current: 99, limit: 12) == 88..<100)
            #expect(CarPlayListTemplates.queueWindow(count: 100, current: 50, limit: 0).isEmpty)
            #expect(CarPlayListTemplates.queueWindow(count: 0, current: 0, limit: 12).isEmpty)
        }

        @Test func emptyListsExplainWhatToDo() throws {
            let session = CarPlayFixture.session(FakeCarPlaySource(), interface: CarPlayTestInterface())
            defer { session.disconnect() }
            let downloads = try CarPlayFixture.rootList(session, 1)
            #expect(downloads.sections.isEmpty)
            #expect(downloads.emptyViewTitleVariants == ["No downloads yet"])
            #expect(downloads.emptyViewSubtitleVariants == ["Download discourses on your iPhone to listen in the car."])
            #expect(try CarPlayFixture.rootList(session, 0).emptyViewTitleVariants == ["Nothing to continue"])
            #expect(try CarPlayFixture.rootList(session, 2).emptyViewTitleVariants == ["No bookmarks yet"])
        }

        @Test func fewerTabsThanSectionsFallsBackToAMenuList() throws {
            let source = FakeCarPlaySource()
            source.pages[.bookmarks] = [CarPlayFixture.bookmark("b1")]
            let interface = CarPlayTestInterface()
            let session = CarPlayFixture.session(source, interface: interface,
                                                 limits: CarPlayTemplateLimits(tabs: 2, items: 20, sections: 1))
            defer { session.disconnect() }
            let menu = try #require(session.rootTemplate as? CPListTemplate)
            let rows = CarPlayFixture.rows(menu)
            #expect(rows.map(\.text) == ["Continue Listening", "Downloads", "Bookmarks"])
            #expect(rows.allSatisfy { $0.accessoryType == .disclosureIndicator })
            try CarPlayFixture.select(rows[2])
            let pushed = try #require(interface.topTemplate as? CPListTemplate)
            #expect(pushed.title == "Bookmarks")
            #expect(CarPlayFixture.rows(pushed).map(\.text) == ["Bookmark b1"])
        }

        @Test func rowsRespectTheVehicleItemLimitAndSayMoreIsOnIPhone() throws {
            let source = FakeCarPlaySource()
            source.pages[.continueListening] = (1...5).map { CarPlayFixture.discourse("d\($0)") }
            let session = CarPlayFixture.session(source, interface: CarPlayTestInterface(),
                                                 limits: CarPlayTemplateLimits(tabs: 4, items: 2, sections: 1))
            defer { session.disconnect() }
            let list = try CarPlayFixture.rootList(session, 0)
            #expect(list.sections.count == 1)
            #expect(CarPlayFixture.rows(list).count == 2)
            #expect(list.sections.first?.header == "First 2 · More on iPhone")
        }

        @Test func zeroSectionsShowsNoRows() throws {
            let source = FakeCarPlaySource()
            source.pages[.continueListening] = [CarPlayFixture.discourse("d1")]
            let session = CarPlayFixture.session(source, interface: CarPlayTestInterface(),
                                                 limits: CarPlayTemplateLimits(tabs: 4, items: 10, sections: 0))
            defer { session.disconnect() }
            #expect(try CarPlayFixture.rootList(session, 0).sections.isEmpty)
        }

        @Test func rowMappingCarriesProgressCurrentIndicatorAndDisclosure() throws {
            let source = FakeCarPlaySource()
            source.pages[.continueListening] = [
                CarPlayFixture.discourse("d1", title: "Playing", progress: 0.4, current: true),
                CarPlayFixture.discourse("d2", title: "Fresh"),
            ]
            source.pages[.downloads] = [CarPlayFixture.series("s1", title: "The Mustard Seed")]
            let session = CarPlayFixture.session(source, interface: CarPlayTestInterface())
            defer { session.disconnect() }
            let rows = CarPlayFixture.rows(try CarPlayFixture.rootList(session, 0))
            #expect(rows.map(\.text) == ["Playing", "Fresh"])
            #expect(rows[0].detailText == "Series")
            #expect(abs(rows[0].playbackProgress - 0.4) < 0.0001)
            #expect(rows[0].isPlaying)
            #expect(rows[0].playingIndicatorLocation == .trailing)
            #expect(rows[1].playbackProgress == 0)
            #expect(!rows[1].isPlaying)
            #expect(rows[0].accessoryType == .none)
            let series = try #require(CarPlayFixture.rows(try CarPlayFixture.rootList(session, 1)).first)
            #expect(series.accessoryType == .disclosureIndicator)
        }

        @Test func nowPlayingIsConfiguredBeforeTheRootIsInstalled() throws {
            let source = FakeCarPlaySource()
            source.queue = [CarPlayQueueEntry(discourseID: "a", title: "A", series: "S"),
                            CarPlayQueueEntry(discourseID: "b", title: "B", series: "S")]
            let interface = CarPlayTestInterface()
            let session = CarPlayFixture.session(source, interface: interface)
            defer { session.disconnect() }
            #expect(interface.nowPlayingButtonsAtRoot == [2])
            let buttons = CPNowPlayingTemplate.shared.nowPlayingButtons
            #expect(buttons.first is CPNowPlayingPlaybackRateButton)
            #expect(buttons.last is CPNowPlayingImageButton)
            #expect(CPNowPlayingTemplate.shared.isUpNextButtonEnabled)
            #expect(CPNowPlayingTemplate.shared.upNextTitle == "Up Next")
        }

        @Test func upNextIsHiddenForASingleDiscourseQueue() throws {
            let source = FakeCarPlaySource()
            source.queue = [CarPlayQueueEntry(discourseID: "a", title: "A", series: "S")]
            let session = CarPlayFixture.session(source, interface: CarPlayTestInterface())
            defer { session.disconnect() }
            #expect(!CPNowPlayingTemplate.shared.isUpNextButtonEnabled)
        }

        @Test func rateCyclesUpwardAndWraps() {
            #expect(CarPlayNowPlayingControls.nextRate(after: 1) == 1.25)
            #expect(CarPlayNowPlayingControls.nextRate(after: 1.75) == 2)
            #expect(CarPlayNowPlayingControls.nextRate(after: 2) == 0.5)
            #expect(CarPlayNowPlayingControls.nextRate(after: 0.5) == 0.75)
            // A rate set elsewhere between steps moves to the next listed one.
            #expect(CarPlayNowPlayingControls.nextRate(after: 1.1) == 1.25)
        }
    }

    @MainActor
    @Suite struct SceneDelegate {
        @Test func audioSceneCallbacksAreVisibleToTheObjectiveCRuntime() {
            let delegate = CarPlaySceneDelegate()
            #expect(delegate.responds(to: NSSelectorFromString("templateApplicationScene:didConnectInterfaceController:")))
            #expect(delegate.responds(to: NSSelectorFromString("templateApplicationScene:didDisconnectInterfaceController:")))
            #expect(NSStringFromClass(CarPlaySceneDelegate.self) == "OshoDiscourses.CarPlaySceneDelegate")
        }
    }
}
#endif
