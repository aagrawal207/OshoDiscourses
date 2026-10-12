import SwiftUI

/// Explains a download that is not moving because of the network, with the one action that helps.
struct DownloadWaitingNotice: View {
    @Environment(DownloadService.self) private var downloads

    var body: some View {
        if let reason = downloads.waitingReason {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    reason == .wifi ? "Waiting for Wi-Fi" : "Waiting for a connection",
                    systemImage: reason == .wifi ? "wifi" : "wifi.slash"
                )
                .font(.subheadline.weight(.semibold))
                Text(reason == .wifi
                     ? "Downloads use Wi-Fi only. Each discourse is about 20–30 MB."
                     : "Downloads continue when you're back online.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if reason == .wifi {
                    Button("Use Mobile Data") { downloads.useMobileData() }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.accent)
                        .accessibilityHint("Downloads now and later can use mobile data. You can change this in Settings.")
                        .accessibilityIdentifier("downloads.useMobileData")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("downloads.waitingNotice")
        }
    }
}

extension DownloadService.WaitingReason {
    var rowLabel: String {
        switch self {
        case .wifi: "Waiting for Wi-Fi"
        case .connection: "Waiting for a connection"
        }
    }
}
