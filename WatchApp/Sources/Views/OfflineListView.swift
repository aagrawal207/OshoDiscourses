import SwiftUI

/// Talks stored on the watch, playable without the phone.
@MainActor
struct OfflineListView: View {
    @Environment(OfflineLibrary.self) private var offline
    @Environment(OfflinePlayer.self) private var player
    @Environment(WatchCompanionModel.self) private var model
    @Binding var path: [WatchRoute]

    var body: some View {
        List {
            let sending = model.requestedTransfers
                .filter { !offline.contains($0.key) }
                .sorted { $0.value < $1.value }
            if offline.entries.isEmpty, sending.isEmpty {
                ContentUnavailableView {
                    Label("Nothing saved yet", systemImage: "applewatch")
                } description: {
                    Text("In Downloads, swipe a talk and tap Save to Watch.")
                }
                .accessibilityIdentifier("watch.offline.empty")
            }
            if !sending.isEmpty {
                Section("Sending from iPhone…") {
                    ForEach(sending, id: \.key) { item in
                        HStack(spacing: 8) {
                            ProgressView().frame(width: 20)
                            Text(item.value).lineLimit(2)
                        }
                        .frame(minHeight: 44)
                        .accessibilityElement(children: .combine)
                        .accessibilityValue("Sending from iPhone")
                    }
                }
            }
            if !offline.entries.isEmpty {
                Section {
                    ForEach(offline.entries) { entry in
                        Button {
                            player.play(entry)
                            path = [.localPlayer]
                        } label: {
                            OfflineRow(entry: entry, isCurrent: player.current?.discourseID == entry.discourseID)
                        }
                        .accessibilityHint("Plays on Apple Watch")
                        .accessibilityIdentifier("watch.offline.\(entry.discourseID)")
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                offline.delete(entry.discourseID)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                        .accessibilityActions {
                            Button("Remove from Watch") { offline.delete(entry.discourseID) }
                        }
                    }
                } header: {
                    Text(summary)
                        .monospacedDigit()
                        .accessibilityIdentifier("watch.offline.storage")
                }
            }
            if offline.lastRejected {
                Text("A talk from iPhone couldn't be saved. Try sending it again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("On Watch")
        .accessibilityIdentifier("watch.offline")
    }

    private var summary: String {
        let count = offline.entries.count
        return (count == 1 ? "1 talk" : "\(count) talks") + " · " + OfflineLibrary.storageLabel(offline.totalBytes)
    }
}

private struct OfflineRow: View {
    let entry: OfflineEntry
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.title)
                .lineLimit(3)
                .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            Text(entry.series)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let progress = entry.progress, !entry.finished {
                ProgressView(value: progress)
                    .accessibilityHidden(true)
            }
            Text(detail)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        if entry.finished { return "Finished" }
        guard entry.duration > 0 else { return "" }
        let left = max(0, entry.duration - entry.position)
        let minutes = Int((left / 60).rounded(.up))
        return entry.position > 0 ? "\(minutes) min left" : "\(minutes) min"
    }
}
