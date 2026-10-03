#if canImport(CarPlay) && !targetEnvironment(macCatalyst)
import CarPlay
import UIKit

/// Vehicle-dependent bounds, read from the SDK at connect so tests can pin them.
@MainActor
struct CarPlayTemplateLimits: Equatable {
    let tabs: Int
    let items: Int
    let sections: Int

    init(tabs: Int = CPTabBarTemplate.maximumTabCount,
         items: Int = Int(CPListTemplate.maximumItemCount),
         sections: Int = Int(CPListTemplate.maximumSectionCount)) {
        self.tabs = max(0, tabs)
        self.items = max(0, items)
        self.sections = max(0, sections)
    }
}

enum CarPlayListKind: Equatable {
    /// Single-list root used when the vehicle allows fewer tabs than sections.
    case menu
    case page(CompanionLocation)
    case queue
}

/// Stored in `CPListTemplate.userInfo`; ties a list to one connection and
/// records which row ids it currently shows so stale taps can be rejected.
@MainActor
final class CarPlayListContext {
    let connection: UUID
    let kind: CarPlayListKind
    fileprivate(set) var rowIDs: [String] = []
    fileprivate(set) var page: CompanionPage?
    fileprivate var items: [CPListItem] = []

    init(connection: UUID, kind: CarPlayListKind) {
        self.connection = connection
        self.kind = kind
    }
}

@MainActor
struct CarPlayListTemplates {
    let limits: CarPlayTemplateLimits

    static let rootLocations: [CompanionLocation] = [.continueListening, .downloads, .bookmarks]

    static func title(for location: CompanionLocation) -> String {
        switch location {
        case .continueListening: return "Continue Listening"
        case .downloads: return "Downloads"
        case .bookmarks: return "Bookmarks"
        case .series: return "Series"
        }
    }

    static func symbol(for location: CompanionLocation) -> String {
        switch location {
        case .continueListening: return "play.circle"
        case .downloads: return "arrow.down.circle"
        case .bookmarks: return "bookmark"
        case .series: return "rectangle.stack"
        }
    }

    static func emptyState(for location: CompanionLocation) -> (title: String, subtitle: String) {
        switch location {
        case .continueListening:
            return ("Nothing to continue", "Talks you start listening to appear here.")
        case .downloads:
            return ("No downloads yet", "Download discourses on your iPhone to listen in the car.")
        case .series:
            return ("No downloads in this series", "Download discourses on your iPhone to listen in the car.")
        case .bookmarks:
            return ("No bookmarks yet", "Bookmarks in downloaded discourses appear here.")
        }
    }

    static func context(of template: CPListTemplate) -> CarPlayListContext? {
        template.userInfo as? CarPlayListContext
    }

    func make(kind: CarPlayListKind, title: String, connection: UUID) -> CPListTemplate {
        let template = CPListTemplate(title: title, sections: [])
        template.userInfo = CarPlayListContext(connection: connection, kind: kind)
        return template
    }

    // MARK: Pages

    /// Updates rows in place when the same ids are shown in the same order, so a
    /// progress refresh neither flickers nor replaces a row under the driver's finger.
    func display(_ page: CompanionPage, on template: CPListTemplate,
                 select: @escaping @MainActor (String) -> Void) {
        guard let context = Self.context(of: template) else { return }
        let rows = limits.sections > 0 ? Array(page.rows.prefix(limits.items)) : []
        let ids = rows.map(\.id)
        let wasTruncated = context.page.map(isTruncated) ?? false
        context.page = page
        let empty = Self.emptyState(for: page.location)
        template.emptyViewTitleVariants = [empty.title]
        template.emptyViewSubtitleVariants = [empty.subtitle]
        if ids == context.rowIDs, context.items.count == rows.count, wasTruncated == isTruncated(page) {
            zip(context.items, rows).forEach { Self.configure($0, with: $1) }
            return
        }
        let items = rows.map { row in
            let item = CPListItem(text: row.title, detailText: row.subtitle)
            Self.configure(item, with: row)
            let rowID = row.id
            item.handler = { @Sendable [weak context] _, completion in
                defer { completion() }
                // CarPlay delivers list selections on the main queue; completion stays on this stack.
                MainActor.assumeIsolated {
                    // The session resolves the id against the page shown now, not the one this row came from.
                    guard context != nil else { return }
                    select(rowID)
                }
            }
            return item
        }
        context.rowIDs = ids
        context.items = items
        let header = isTruncated(page) ? "First \(items.count) · More on iPhone" : nil
        template.updateSections(items.isEmpty ? [] : [CPListSection(items: items, header: header, sectionIndexTitle: nil)])
    }

    private func isTruncated(_ page: CompanionPage) -> Bool {
        page.isTruncated || page.rows.count > limits.items
    }

    static func configure(_ item: CPListItem, with row: CompanionRow) {
        item.setText(row.title)
        item.setDetailText(row.subtitle)
        item.playbackProgress = CGFloat(min(1, max(0, row.progress ?? 0)))
        item.isPlaying = row.isCurrent
        item.playingIndicatorLocation = .trailing
        item.accessoryType = row.kind == .series ? .disclosureIndicator : .none
        let symbol: String
        switch row.kind {
        case .discourse: symbol = "waveform"
        case .bookmark: symbol = "bookmark"
        case .series: symbol = "rectangle.stack"
        }
        item.setImage(UIImage(systemName: symbol))
    }

    // MARK: Menu (fallback root)

    func displayMenu(on template: CPListTemplate, select: @escaping @MainActor (CompanionLocation) -> Void) {
        guard let context = Self.context(of: template), limits.sections > 0 else { return }
        let items = Self.rootLocations.prefix(limits.items).map { location in
            let item = CPListItem(text: Self.title(for: location), detailText: nil,
                                  image: UIImage(systemName: Self.symbol(for: location)))
            item.accessoryType = .disclosureIndicator
            item.handler = { @Sendable [weak context] _, completion in
                defer { completion() }
                MainActor.assumeIsolated {
                    guard context != nil else { return }
                    select(location)
                }
            }
            return item
        }
        context.rowIDs = Self.rootLocations.prefix(limits.items).map { Self.title(for: $0) }
        context.items = Array(items)
        template.updateSections([CPListSection(items: Array(items))])
    }

    // MARK: Up Next

    func displayQueue(_ queue: [CarPlayQueueEntry], currentIndex: Int, on template: CPListTemplate,
                      select: @escaping @MainActor (Int, String) -> Void) {
        guard let context = Self.context(of: template) else { return }
        template.emptyViewTitleVariants = ["Nothing queued"]
        template.emptyViewSubtitleVariants = ["Choose a discourse to start its series."]
        let window = limits.sections > 0 ? Self.queueWindow(count: queue.count, current: currentIndex, limit: limits.items) : 0..<0
        let shown = Array(queue.enumerated())[window]
        let items = shown.map { index, entry in
            let item = CPListItem(text: entry.title, detailText: entry.series, image: UIImage(systemName: "waveform"))
            item.isPlaying = index == currentIndex
            item.playingIndicatorLocation = .trailing
            let id = entry.discourseID
            item.handler = { @Sendable [weak context] _, completion in
                defer { completion() }
                MainActor.assumeIsolated {
                    guard context != nil else { return }
                    select(index, id)
                }
            }
            return item
        }
        context.rowIDs = shown.map { "\($0.offset):\($0.element.discourseID)" }
        context.items = items
        let header = queue.count > items.count ? "\(items.count) of \(queue.count) · More on iPhone" : nil
        template.updateSections(items.isEmpty ? [] : [CPListSection(items: items, header: header, sectionIndexTitle: nil)])
    }

    /// Rows shown when the vehicle allows fewer rows than the queue holds: the
    /// playing discourse and what follows it, so the current row is always reachable.
    nonisolated static func queueWindow(count: Int, current: Int, limit: Int) -> Range<Int> {
        guard count > 0, limit > 0 else { return 0..<0 }
        guard count > limit else { return 0..<count }
        let start = min(max(0, current - 1), count - limit)
        return start..<(start + limit)
    }
}
#endif
