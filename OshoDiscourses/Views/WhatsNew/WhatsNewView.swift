import SwiftUI

/// What changed in this version, what the listener missed since their last update, and the full history.
struct WhatsNewView: View {
    let content: WhatsNewContent
    /// After an update the screen leads with a large heading and a Continue button; from Settings it is a page.
    var isAnnouncement = false
    var onContinue: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    private var accent: Color { UserSettings.shared.effectiveAccentTheme.color }

    var body: some View {
        List {
            Section {
                if let highlights = content.current.highlights, !highlights.isEmpty {
                    ForEach(highlights, id: \.self) { highlight in
                        HighlightRow(highlight: highlight, accent: accent)
                    }
                } else {
                    ForEach(Array(content.current.items.enumerated()), id: \.offset) { _, item in
                        ReleaseItemRow(text: item)
                    }
                }
            } header: {
                Text("Version \(content.current.version)")
            } footer: {
                if content.current.highlights?.isEmpty == false, content.current.items.count > content.current.highlights?.count ?? 0 {
                    NavigationLink("All changes in \(content.current.version)") {
                        ReleaseList(title: "Version \(content.current.version)", releases: [content.current], showsHeaders: false)
                    }
                    .font(.footnote.weight(.semibold))
                    .padding(.top, 4)
                }
            }

            if !content.sinceLastSeen.isEmpty {
                ForEach(content.sinceLastSeen) { release in
                    Section("Also new since your last update · \(release.version)") {
                        ForEach(Array(release.items.enumerated()), id: \.offset) { _, item in
                            ReleaseItemRow(text: item)
                        }
                    }
                }
            }

            if !content.earlier.isEmpty {
                Section {
                    NavigationLink {
                        ReleaseList(title: "Earlier Updates", releases: content.earlier, showsHeaders: true)
                    } label: {
                        Label("Earlier Updates", systemImage: "clock.arrow.circlepath")
                    }
                    .accessibilityIdentifier("whatsNew.earlier")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("What's New")
        .navigationBarTitleDisplayMode(isAnnouncement ? .large : .inline)
        .accessibilityIdentifier("whatsNew.list")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isAnnouncement {
                Button {
                    onContinue()
                    dismiss()
                } label: {
                    Text("Continue").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
                .accessibilityIdentifier("whatsNew.continue")
            }
        }
    }
}

private struct HighlightRow: View {
    let highlight: AppRelease.Highlight
    let accent: Color

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: highlight.symbol)
                .font(.title2)
                .foregroundStyle(accent)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(highlight.title).font(.headline)
                Text(highlight.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

private struct ReleaseItemRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 2)
    }
}

private struct ReleaseList: View {
    let title: String
    let releases: [AppRelease]
    let showsHeaders: Bool

    var body: some View {
        List {
            ForEach(releases) { release in
                Section {
                    ForEach(Array(release.items.enumerated()), id: \.offset) { _, item in
                        ReleaseItemRow(text: item)
                    }
                } header: {
                    if showsHeaders { Text("Version \(release.version)") }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The once-per-update sheet, wrapped so each window can present it from its root.
struct WhatsNewSheet: View {
    let content: WhatsNewContent
    let onFinish: () -> Void

    var body: some View {
        NavigationStack {
            WhatsNewView(content: content, isAnnouncement: true, onContinue: onFinish)
        }
        .tint(UserSettings.shared.effectiveAccentTheme.color)
        .presentationDragIndicator(.visible)
        // Swiping the sheet away counts as seen, like Continue.
        .onDisappear(perform: onFinish)
    }
}
