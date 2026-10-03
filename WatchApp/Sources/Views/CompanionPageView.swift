import SwiftUI

/// One page of the phone's library. Discourse and bookmark rows play on iPhone; series rows open their talks.
@MainActor
struct CompanionPageView: View {
    @Environment(WatchCompanionModel.self) private var model
    @Environment(OfflineLibrary.self) private var offline
    @Environment(OfflinePlayer.self) private var localPlayer
    @State private var isVisible = false
    let location: CompanionLocation
    @Binding var path: [WatchRoute]

    var body: some View {
        List {
            if let notice = model.notice { NoticeRow(message: notice) }
            if let page = model.pages[location] {
                if page.rows.isEmpty {
                    Text(page.emptyMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("watch.page.empty")
                }
                ForEach(page.rows) { row in rowView(row) }
                if page.isTruncated {
                    Text("Showing the first \(page.rows.count). Open Osho Talks on iPhone for the rest.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if !model.connection.canMessage { ConnectionRow() }
            } else if !model.connection.canMessage {
                ConnectionRow()
            } else if let error = model.pageErrors[location] {
                Text(error).font(.footnote).foregroundStyle(.secondary)
                reloadButton
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading from iPhone…").font(.footnote)
                }
                .frame(minHeight: 44)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("watch.page.loading")
            }
            if model.pages[location] != nil, let error = model.pageErrors[location] {
                Text(error).font(.footnote).foregroundStyle(.secondary)
                reloadButton
            }
        }
        .navigationTitle(Self.title(for: location, page: model.pages[location]))
        .task(id: model.contentRevision) { await model.loadPage(location) }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .accessibilityIdentifier("watch.page")
    }

    @ViewBuilder
    private func rowView(_ row: CompanionRow) -> some View {
        switch row.kind {
        case .series:
            NavigationLink(value: WatchRoute.page(.series(row.id))) {
                RowLabel(row: row, symbol: "square.stack", status: nil)
            }
            .accessibilityIdentifier("watch.row.\(row.id)")
        case .bookmark:
            Button { play(row) } label: {
                RowLabel(row: row, symbol: "bookmark.fill", status: nil)
            }
            .disabled(!model.canChooseItem)
            .accessibilityHint("Plays on iPhone")
            .accessibilityIdentifier("watch.row.\(row.id)")
        case .discourse:
            let discourseID = Self.discourseID(row.id)
            let onWatch = discourseID.map(offline.contains) ?? false
            let sending = discourseID.map { model.requestedTransfers[$0] != nil && !onWatch } ?? false
            Button { play(row) } label: {
                RowLabel(row: row, symbol: nil, status: onWatch ? .onWatch : sending ? .sending : nil)
            }
            .disabled(!model.canChooseItem)
            .accessibilityHint("Plays on iPhone")
            .accessibilityIdentifier("watch.row.\(row.id)")
            .swipeActions(edge: .trailing) {
                if let discourseID, !onWatch, !sending {
                    Button { save(discourseID, title: row.title) } label: {
                        Label("Save to Watch", systemImage: "applewatch.radiowaves.left.and.right")
                    }
                    .tint(model.accent.color)
                }
            }
            .accessibilityActions {
                if let discourseID, !onWatch, !sending {
                    Button("Save to Watch") { save(discourseID, title: row.title) }
                }
            }
        }
    }

    private func play(_ row: CompanionRow) {
        Task {
            let accepted = await model.play(row)
            guard accepted, isVisible else { return }
            if localPlayer.isPlaying { localPlayer.pause() }
            path = [.remotePlayer]
        }
    }

    private func save(_ discourseID: String, title: String) {
        Task { await model.saveToWatch(discourseID: discourseID, title: title) }
    }

    private var reloadButton: some View {
        Button {
            Task { await model.loadPage(location, force: true) }
        } label: {
            Label("Try Again", systemImage: "arrow.clockwise")
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .disabled(model.loadingPages.contains(location) || !model.connection.canMessage)
    }

    static func discourseID(_ rowID: String) -> String? {
        guard rowID.hasPrefix("d:") else { return nil }
        let id = String(rowID.dropFirst(2))
        return id.isEmpty ? nil : id
    }

    /// Short fixed titles fit the watch's navigation bar; only series use the phone's name.
    static func title(for location: CompanionLocation, page: CompanionPage?) -> String {
        switch location {
        case .continueListening: "Continue"
        case .downloads: "Downloads"
        case .series: page?.title ?? "Series"
        case .bookmarks: "Bookmarks"
        }
    }
}

private struct RowLabel: View {
    enum Status { case onWatch, sending }

    let row: CompanionRow
    let symbol: String?
    let status: Status?

    var body: some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .lineLimit(3)
                    .foregroundStyle(row.isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                if !row.subtitle.isEmpty {
                    Text(row.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                switch status {
                case .onWatch:
                    Label("On Watch", systemImage: "applewatch")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .sending:
                    Label("Sending from iPhone…", systemImage: "arrow.down.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case nil:
                    EmptyView()
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(row.isCurrent ? "Now playing" : "")
    }
}
