#if canImport(WatchConnectivity) && !targetEnvironment(macCatalyst)
import SwiftUI

/// Settings > Apple Watch: what is on the Watch and what is still sending.
/// The Watch chooses what to keep; this screen only reports and explains.
struct AppleWatchView: View {
    private let transfers: WatchTransferService?

    init(transfers: WatchTransferService? = WatchPhoneSession.shared.transfers) {
        self.transfers = transfers
    }

    var body: some View {
        List {
            if let transfers {
                if let status = Self.statusMessage(transfers.linkState) {
                    Section {
                        Label(status, systemImage: "applewatch.slash")
                            .foregroundStyle(.secondary)
                    }
                }
                sendingSection(transfers)
                failedSection(transfers)
                onWatchSection(transfers)
            } else {
                Section {
                    Text("Apple Watch isn't available on this device.")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                EmptyView()
            } footer: {
                Text("Open Osho Talks on Apple Watch to choose discourses to keep there. Deleting a download on iPhone keeps the copy on Apple Watch.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Apple Watch")
        .navigationBarTitleDisplayMode(.inline)
        .reservesMiniPlayerSpace()
        .onAppear { transfers?.refresh() }
    }

    @ViewBuilder
    private func sendingSection(_ transfers: WatchTransferService) -> some View {
        let ids = transfers.sending.sorted()
        if !ids.isEmpty {
            Section("Sending") {
                ForEach(ids, id: \.self) { id in
                    HStack {
                        DiscourseLabel(discourseID: id)
                        Spacer()
                        ProgressView()
                            .accessibilityLabel("Sending")
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    @ViewBuilder
    private func failedSection(_ transfers: WatchTransferService) -> some View {
        let failed = transfers.failures.keys.filter { !transfers.sending.contains($0) }.sorted()
        if !failed.isEmpty {
            Section("Couldn't Send") {
                ForEach(failed, id: \.self) { id in
                    VStack(alignment: .leading, spacing: 4) {
                        DiscourseLabel(discourseID: id)
                        if let message = transfers.failures[id] {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func onWatchSection(_ transfers: WatchTransferService) -> some View {
        Section("On Apple Watch") {
            if transfers.inventory.isEmpty {
                Text("No discourses on Apple Watch yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(transfers.inventory, id: \.self) { id in
                    DiscourseLabel(discourseID: id)
                }
            }
        }
    }

    static func statusMessage(_ state: WatchLinkState) -> String? {
        switch state {
        case .ready(let paired, let installed, _):
            if !paired { return "Pair an Apple Watch with this iPhone to keep discourses on it." }
            if !installed { return "Install Osho Talks on your Apple Watch from the Watch app on iPhone." }
            return nil
        case .activating: return nil
        case .unsupported: return "Apple Watch isn't available on this device."
        case .inactive, .failed: return "Your iPhone can't reach Apple Watch right now."
        }
    }
}

private struct DiscourseLabel: View {
    let discourseID: String

    var body: some View {
        // displayTitle already names the series ("Series - #3").
        Text(Catalog.discourseLookup[discourseID]?.discourse.displayTitle ?? "Removed discourse")
    }
}
#endif
