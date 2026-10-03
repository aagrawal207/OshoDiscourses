#if canImport(CarPlay) && !targetEnvironment(macCatalyst)
import CarPlay
import Foundation
import MediaPlayer
import Testing
@testable import OshoDiscourses

/// Parent of every CarPlay suite: `CPNowPlayingTemplate.shared` is process-global,
/// so the suites must not interleave.
@MainActor
@Suite(.serialized)
struct CarPlayTests {}

// MARK: - Interface transport fake

@MainActor
final class CarPlayTestInterface: CarPlayInterfaceTransport {
    enum Operation: Equatable { case root, push, pop, popToRoot, present, dismiss }

    private struct Pending {
        let operation: Operation
        let template: CPTemplate?
        let tab: ObjectIdentifier?
        let completion: CarPlayInterfaceCompletion
    }

    weak var delegate: (any CPInterfaceControllerDelegate)?
    var automaticallyCompletes = true
    private(set) var root: CPTemplate?
    private(set) var operations: [Operation] = []
    private(set) var pushed: [CPTemplate] = []
    private(set) var presented: [CPTemplate] = []
    private(set) var presentedTemplate: CPTemplate?
    private(set) var nowPlayingButtonsAtRoot: [Int] = []
    private var stacks: [ObjectIdentifier: [CPTemplate]] = [:]
    private var selectedRoot: CPTemplate?
    private var pending: [Pending] = []

    var templates: [CPTemplate] {
        guard let selectedRoot else { return [] }
        return stacks[ObjectIdentifier(selectedRoot)] ?? []
    }
    var topTemplate: CPTemplate? { templates.last }
    var pendingCount: Int { pending.count }

    func setRoot(_ template: CPTemplate, completion: @escaping CarPlayInterfaceCompletion) {
        nowPlayingButtonsAtRoot.append(CPNowPlayingTemplate.shared.nowPlayingButtons.count)
        submit(.root, template: template, completion: completion)
    }
    func push(_ template: CPTemplate, completion: @escaping CarPlayInterfaceCompletion) {
        pushed.append(template)
        submit(.push, template: template, completion: completion)
    }
    func pop(to template: CPTemplate, completion: @escaping CarPlayInterfaceCompletion) {
        submit(.pop, template: template, completion: completion)
    }
    func popToRoot(completion: @escaping CarPlayInterfaceCompletion) {
        submit(.popToRoot, template: nil, completion: completion)
    }
    func present(_ template: CPTemplate, completion: @escaping CarPlayInterfaceCompletion) {
        presented.append(template)
        submit(.present, template: template, completion: completion)
    }
    func dismissPresented(completion: @escaping CarPlayInterfaceCompletion) {
        submit(.dismiss, template: nil, completion: completion)
    }

    func completeNext(success: Bool = true, message: String? = nil) throws {
        let call = try #require(pending.first)
        pending.removeFirst()
        if success { apply(call) }
        call.completion(success, message)
    }

    func selectTab(at index: Int) throws {
        let tabs = try #require(root as? CPTabBarTemplate)
        let list = tabs.templates[index]
        selectedRoot = list
        tabs.delegate?.tabBarTemplate(tabs, didSelect: list)
        notifyAppearance()
    }

    func back() {
        guard let selectedRoot, templates.count > 1 else { return }
        stacks[ObjectIdentifier(selectedRoot)] = Array(templates.dropLast())
        notifyAppearance()
    }

    private func submit(_ operation: Operation, template: CPTemplate?, completion: @escaping CarPlayInterfaceCompletion) {
        operations.append(operation)
        let call = Pending(operation: operation, template: template,
                           tab: selectedRoot.map(ObjectIdentifier.init), completion: completion)
        if automaticallyCompletes {
            apply(call)
            completion(true, nil)
        } else {
            pending.append(call)
        }
    }

    private func apply(_ call: Pending) {
        switch call.operation {
        case .root:
            guard let root = call.template else { return }
            self.root = root
            let roots = (root as? CPTabBarTemplate)?.templates ?? [root]
            stacks = Dictionary(uniqueKeysWithValues: roots.map { (ObjectIdentifier($0), [$0]) })
            selectedRoot = roots.first
            notifyAppearance()
            return
        case .present:
            presentedTemplate = call.template
            return
        case .dismiss:
            presentedTemplate = nil
            return
        default: break
        }
        guard let tab = call.tab, var stack = stacks[tab] else { return }
        switch call.operation {
        case .push: if let template = call.template { stack.append(template) }
        case .pop: if let index = stack.firstIndex(where: { $0 === call.template }) { stack = Array(stack.prefix(index + 1)) }
        case .popToRoot: stack = Array(stack.prefix(1))
        default: break
        }
        stacks[tab] = stack
        if selectedRoot.map(ObjectIdentifier.init) == tab { notifyAppearance() }
    }

    private func notifyAppearance() {
        guard let topTemplate else { return }
        delegate?.templateWillAppear?(topTemplate, animated: false)
        delegate?.templateDidAppear?(topTemplate, animated: false)
    }
}

// MARK: - Content source fake

@MainActor
final class FakeCarPlaySource: CarPlayContentSource {
    var pages: [CompanionLocation: [CompanionRow]] = [:]
    var truncated: Set<CompanionLocation> = []
    var failures: [String: PlaybackLauncher.Failure] = [:]
    private(set) var played: [String] = []
    private(set) var pageRequests: [CompanionLocation] = []
    private(set) var playedQueueIndices: [Int] = []
    private(set) var rates: [Float] = []
    private(set) var bookmarksAdded = 0
    private(set) var observations: [CarPlayObservation] = []
    private var handlers: [@MainActor @Sendable () -> Void] = []

    var currentDiscourseID: String?
    var isPlaying = false
    var queue: [CarPlayQueueEntry] = []
    var currentQueueIndex = 0
    var playbackRate: Float = 1

    func page(for location: CompanionLocation, maximumRows: Int) -> CompanionPage {
        pageRequests.append(location)
        let rows = pages[location] ?? []
        return CompanionPage(location: location, title: CarPlayListTemplates.title(for: location),
                             rows: Array(rows.prefix(maximumRows)),
                             isTruncated: truncated.contains(location) || rows.count > maximumRows, emptyMessage: "")
    }

    func play(rowID: String) throws(PlaybackLauncher.Failure) {
        if let failure = failures[rowID] { throw failure }
        played.append(rowID)
    }

    func playQueueItem(at index: Int) {
        playedQueueIndices.append(index)
        currentQueueIndex = index
    }

    func setRate(_ rate: Float) {
        rates.append(rate)
        playbackRate = rate
    }

    func addBookmarkAtCurrentTime() -> Bool {
        guard currentDiscourseID != nil else { return false }
        bookmarksAdded += 1
        return true
    }

    func observeChanges(_ onChange: @escaping @MainActor @Sendable () -> Void) -> CarPlayObservation {
        let token = CarPlayObservation()
        observations.append(token)
        handlers.append(onChange)
        return token
    }

    func fireChange() {
        for (token, handler) in zip(observations, handlers) where !token.isCancelled { handler() }
    }
}

// MARK: - Helpers

final class CompletionCount: @unchecked Sendable {
    var value = 0
}

@MainActor
enum CarPlayFixture {
    static let limits = CarPlayTemplateLimits(tabs: 4, items: 100, sections: 10)

    static func discourse(_ id: String, title: String? = nil, progress: Double? = nil, current: Bool = false) -> CompanionRow {
        CompanionRow(id: CompanionLibrary.rowID(discourse: id), kind: .discourse, title: title ?? "Talk \(id)",
                     subtitle: "Series", progress: progress, isCurrent: current)
    }

    static func series(_ id: String, title: String) -> CompanionRow {
        CompanionRow(id: CompanionLibrary.rowID(series: id), kind: .series, title: title, subtitle: "2 discourses")
    }

    static func bookmark(_ id: String) -> CompanionRow {
        CompanionRow(id: CompanionLibrary.rowID(bookmark: id), kind: .bookmark, title: "Bookmark \(id)", subtitle: "1:00")
    }

    static func session(_ source: FakeCarPlaySource, interface: CarPlayTestInterface,
                        limits: CarPlayTemplateLimits = limits,
                        progress: Duration = .seconds(3600)) -> CarPlaySessionController {
        let session = CarPlaySessionController(interface: interface, source: source, limits: limits,
                                               progressRefreshInterval: progress)
        session.connect()
        return session
    }

    static func rootList(_ session: CarPlaySessionController, _ index: Int) throws -> CPListTemplate {
        let tabs = try #require(session.rootTemplate as? CPTabBarTemplate)
        return try #require(tabs.templates[index] as? CPListTemplate)
    }

    static func rows(_ list: CPListTemplate) -> [CPListItem] {
        list.sections.flatMap(\.items).compactMap { $0 as? CPListItem }
    }

    /// Invokes a row's handler as CarPlay would and checks completion ran exactly once.
    static func select(_ row: CPListItem) throws {
        let handler = try #require(row.handler)
        let count = CompletionCount()
        handler(row) { count.value += 1 }
        #expect(count.value == 1, "List selections must complete synchronously, once")
    }

    static func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }
}
#endif
