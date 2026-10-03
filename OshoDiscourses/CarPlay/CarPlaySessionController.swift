#if canImport(CarPlay) && !targetEnvironment(macCatalyst)
import CarPlay
import OSLog
import UIKit

/// One CarPlay connection: root tabs, list refresh, selection and Now Playing.
/// Playback state lives in the phone's services; ending the session leaves it alone.
@MainActor
final class CarPlaySessionController: NSObject, CPInterfaceControllerDelegate, CPTabBarTemplateDelegate {
    enum SelectionOutcome: String { case played, opened, stale, failed }

    private let interface: any CarPlayInterfaceTransport
    private let source: any CarPlayContentSource
    private let configuredLimits: CarPlayTemplateLimits?
    private let progressRefreshInterval: Duration
    private let navigator: CarPlayTemplateNavigator
    private let log = Logger(subsystem: "com.agraabhi.oshodiscourses", category: "CarPlay")
    private var lists = CarPlayListTemplates(limits: CarPlayTemplateLimits(tabs: 0, items: 0, sections: 0))
    private var connection = UUID()
    private var observation: CarPlayObservation?
    private var refreshTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private weak var visibleList: CPListTemplate?
    private(set) var rootLists: [CPListTemplate] = []
    private(set) var rootTemplate: CPTemplate?
    private(set) var nowPlayingControls: CarPlayNowPlayingControls?
    private(set) var isConnected = false
    /// Last selection result, for tests; logs carry the same bounded value.
    private(set) var lastSelectionOutcome: SelectionOutcome?
    private(set) var lastFailureMessage: String?

    init(interface: any CarPlayInterfaceTransport, source: any CarPlayContentSource,
         limits: CarPlayTemplateLimits? = nil, progressRefreshInterval: Duration = .seconds(10)) {
        self.interface = interface
        self.source = source
        configuredLimits = limits
        self.progressRefreshInterval = progressRefreshInterval
        navigator = CarPlayTemplateNavigator(interface: interface)
        super.init()
    }

    isolated deinit { disconnect() }

    // MARK: Lifecycle

    func connect() {
        disconnect()
        connection = UUID()
        isConnected = true
        lists = CarPlayListTemplates(limits: configuredLimits ?? CarPlayTemplateLimits())
        interface.delegate = self
        let connected = connection
        // Configured before the root so a system-opened Now Playing already has its buttons.
        nowPlayingControls = CarPlayNowPlayingControls(source: source) { [weak self] in
            guard let self, self.isCurrent(connected) else { return }
            self.openUpNext()
        }
        let root: CPTemplate
        if lists.limits.tabs >= CarPlayListTemplates.rootLocations.count {
            rootLists = CarPlayListTemplates.rootLocations.map { location in
                let list = lists.make(kind: .page(location), title: CarPlayListTemplates.title(for: location), connection: connection)
                list.tabTitle = CarPlayListTemplates.title(for: location)
                list.tabImage = UIImage(systemName: CarPlayListTemplates.symbol(for: location))
                return list
            }
            let tabs = CPTabBarTemplate(templates: rootLists)
            tabs.delegate = self
            root = tabs
        } else {
            let menu = lists.make(kind: .menu, title: "Osho Talks", connection: connection)
            rootLists = [menu]
            root = menu
        }
        rootLists.forEach(load)
        visibleList = rootLists.first
        rootTemplate = root
        log.info("event=connect tabs=\(self.rootLists.count, privacy: .public)")
        navigator.installRoot(root) { [weak self] message in
            guard let self, self.isCurrent(connected) else { return }
            self.log.error("event=root_template_failed")
            self.presentFailure(message)
        }
        observation = source.observeChanges { [weak self] in
            guard let self, self.isCurrent(connected) else { return }
            self.scheduleRefresh()
        }
        startProgressRefresh()
    }

    /// Cancels CarPlay-only work. Never pauses playback or clears Now Playing info.
    func disconnect() {
        let wasConnected = isConnected
        isConnected = false
        connection = UUID()
        refreshTask?.cancel()
        progressTask?.cancel()
        refreshTask = nil
        progressTask = nil
        observation?.cancel()
        observation = nil
        navigator.disconnect()
        nowPlayingControls?.disconnect()
        nowPlayingControls = nil
        if interface.delegate === self { interface.delegate = nil }
        if let tabs = rootTemplate as? CPTabBarTemplate, tabs.delegate === self { tabs.delegate = nil }
        visibleList = nil
        rootLists = []
        rootTemplate = nil
        if wasConnected { log.info("event=disconnect") }
    }

    // MARK: Interface delegate

    func templateWillAppear(_ aTemplate: CPTemplate, animated: Bool) {
        guard isConnected else { return }
        if let list = aTemplate as? CPListTemplate, context(for: list) != nil {
            visibleList = list
            load(list)
        } else if let tabs = aTemplate as? CPTabBarTemplate {
            if let list = (tabs.selectedTemplate ?? rootLists.first) as? CPListTemplate {
                visibleList = list
                load(list)
            }
        } else {
            visibleList = nil
        }
    }

    func tabBarTemplate(_ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate) {
        guard isConnected, tabBarTemplate === rootTemplate else { return }
        navigator.userChangedNavigation()
        if let list = selectedTemplate as? CPListTemplate, context(for: list) != nil {
            visibleList = list
            load(list)
        }
    }

    // MARK: Loading

    /// Reloads every root list and the visible pushed list. Root lists are local
    /// reads, so keeping hidden tabs fresh is cheaper than tracking which are stale.
    func refresh() {
        guard isConnected else { return }
        nowPlayingControls?.update()
        rootLists.forEach(load)
        if let visibleList, !rootLists.contains(where: { $0 === visibleList }) { load(visibleList) }
    }

    func refreshVisibleList() {
        guard isConnected, let visibleList else { return }
        load(visibleList)
    }

    private func load(_ list: CPListTemplate) {
        guard let context = context(for: list) else { return }
        let connected = connection
        switch context.kind {
        case .menu:
            lists.displayMenu(on: list) { [weak self] location in
                guard let self, self.isCurrent(connected) else { return }
                self.open(location, title: CarPlayListTemplates.title(for: location))
            }
        case .page(let location):
            let page = source.page(for: location, maximumRows: lists.limits.items)
            lists.display(page, on: list) { [weak self, weak list] rowID in
                guard let self, let list, self.isCurrent(connected) else { return }
                self.select(rowID, from: list)
            }
        case .queue:
            lists.displayQueue(source.queue, currentIndex: source.currentQueueIndex, on: list) { [weak self, weak list] index, id in
                guard let self, let list, self.isCurrent(connected) else { return }
                self.selectQueueEntry(at: index, discourseID: id, from: list)
            }
        }
    }

    private func scheduleRefresh() {
        guard isConnected, refreshTask == nil else { return }
        let connected = connection
        refreshTask = Task { @MainActor [weak self] in
            guard let self, self.isCurrent(connected), !Task.isCancelled else { return }
            self.refreshTask = nil
            self.refresh()
        }
    }

    private func startProgressRefresh() {
        let connected = connection
        let interval = progressRefreshInterval
        progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, self.isCurrent(connected), !Task.isCancelled else { return }
                if self.source.isPlaying { self.refreshVisibleList() }
            }
        }
    }

    // MARK: Selection

    private func select(_ rowID: String, from list: CPListTemplate) {
        guard let context = context(for: list), let row = context.page?.rows.first(where: { $0.id == rowID }),
              context.rowIDs.contains(rowID) else {
            record(.stale, kind: "row")
            load(list)
            return
        }
        navigator.userChangedNavigation()
        switch row.kind {
        case .series:
            guard case .series(let seriesID)? = CompanionLibrary.resolve(row.id) else { record(.stale, kind: "series"); return }
            open(.series(seriesID), title: row.title)
            record(.opened, kind: "series")
        case .discourse, .bookmark:
            let kind = row.kind.rawValue
            do {
                try source.play(rowID: row.id)
                record(.played, kind: kind)
                showNowPlaying()
            } catch {
                record(.failed, kind: kind, reason: "\(error)")
                presentFailure(error.message)
                load(list)
            }
        }
    }

    private func selectQueueEntry(at index: Int, discourseID: String, from list: CPListTemplate) {
        let queue = source.queue
        guard queue.indices.contains(index), queue[index].discourseID == discourseID else {
            record(.stale, kind: "queue")
            load(list)
            return
        }
        navigator.userChangedNavigation()
        if index != source.currentQueueIndex { source.playQueueItem(at: index) }
        record(.played, kind: "queue")
        showNowPlaying()
    }

    private func open(_ location: CompanionLocation, title: String) {
        let list = lists.make(kind: .page(location), title: title, connection: connection)
        load(list)
        show(list)
    }

    private func openUpNext() {
        guard isConnected else { return }
        navigator.userChangedNavigation()
        let existing = interface.templates.compactMap { $0 as? CPListTemplate }.first { context(for: $0)?.kind == .queue }
        let queue = existing ?? lists.make(kind: .queue, title: "Up Next", connection: connection)
        load(queue)
        show(queue)
    }

    private func showNowPlaying() {
        show(CPNowPlayingTemplate.shared)
    }

    private func show(_ template: CPTemplate) {
        let connected = connection
        navigator.show(template) { [weak self] message in
            guard let self, self.isCurrent(connected) else { return }
            self.log.error("event=navigation_failed")
            self.presentFailure(message)
        }
    }

    // MARK: Failures

    private func presentFailure(_ message: String) {
        guard isConnected else { return }
        lastFailureMessage = message
        let connected = connection
        let alert = CPAlertTemplate(titleVariants: [message], actions: [
            CPAlertAction(title: "OK", style: .cancel) { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrent(connected) else { return }
                    self.interface.dismissPresented { _, _ in }
                }
            },
        ])
        let present = { @MainActor [weak self] in
            guard let self, self.isCurrent(connected) else { return }
            self.interface.present(alert) { [weak self] success, _ in
                guard let self, self.isCurrent(connected), !success else { return }
                self.log.error("event=alert_failed")
            }
        }
        if interface.presentedTemplate != nil {
            interface.dismissPresented { _, _ in present() }
        } else {
            present()
        }
    }

    private func record(_ outcome: SelectionOutcome, kind: String, reason: String? = nil) {
        lastSelectionOutcome = outcome
        log.info("event=selection kind=\(kind, privacy: .public) outcome=\(outcome.rawValue, privacy: .public) reason=\(reason ?? "none", privacy: .public)")
    }

    // MARK: Identity

    private func context(for list: CPListTemplate) -> CarPlayListContext? {
        guard isConnected, let context = CarPlayListTemplates.context(of: list), context.connection == connection else { return nil }
        return context
    }

    private func isCurrent(_ connected: UUID) -> Bool { isConnected && connection == connected }
}
#endif
