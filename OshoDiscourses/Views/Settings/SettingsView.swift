import SwiftUI

struct SettingsView: View {
    @Bindable private var settings = UserSettings.shared
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.openURL) private var openURL
    @State private var showMailClientPicker = false

    var body: some View {
        NavigationStack {
            Form {
                contentSection
                playerSection
                noiseReductionSection
                appearanceSection
                aboutSection
            }
            // Use the Form's native grouped background so sections render as
            // rounded cards: light-gray page + white cards in light mode, true
            // black + dark-gray cards in dark mode. (An earlier systemBackground
            // override flattened the cards to invisible in light mode.)
            .navigationTitle("Settings")
            .safeAreaInset(edge: .bottom) {
                Spacer().frame(height: 70)
            }
        }
    }

    // MARK: - Content (Language)

    private var contentSection: some View {
        Section {
            Picker("Language", selection: $settings.languageFilter) {
                Text("Both").tag(LanguageFilter.both)
                Text("English").tag(LanguageFilter.english)
                Text("Hindi").tag(LanguageFilter.hindi)
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Content Language")
        }
        .listRowBackground(Color(.secondarySystemGroupedBackground))
    }

    // MARK: - Player & Downloads

    private var playerSection: some View {
        Section {
            Toggle("Auto-Play Next", isOn: $settings.autoPlayNext)
            Toggle("Smart Download", isOn: $settings.smartDownload)
            Toggle("Smart Delete", isOn: $settings.smartDelete)
            Toggle("Download over Cellular", isOn: $settings.allowCellularDownloads)
        } header: {
            Text("Player & Downloads")
        } footer: {
            Text("Downloads use Wi-Fi only unless this is on. Each discourse is roughly 20–30 MB.")
        }
        .listRowBackground(Color(.secondarySystemGroupedBackground))
    }

    // MARK: - Noise Reduction

    @ViewBuilder
    private var noiseReductionSection: some View {
        @Bindable var player = player
        Section {
            Toggle("Noise Reduction", isOn: $player.isNoiseReductionEnabled)

            if player.isNoiseReductionEnabled {
                Picker("Strength", selection: $player.denoiseStrength) {
                    ForEach(AudioPlayerService.DenoiseStrength.allCases, id: \.self) { strength in
                        Text(strength.label).tag(strength)
                    }
                }
                .pickerStyle(.segmented)
            }
        } header: {
            Text("Noise Reduction")
        } footer: {
            Text("Reduces background hiss and hum during playback using on-device speech filtering. It can slightly soften the voice — Light keeps speech clearest, Strong removes the most noise. You can also long-press the Denoise button in the player to change strength.")
        }
        .listRowBackground(Color(.secondarySystemGroupedBackground))
    }

    // MARK: - Appearance

    @ViewBuilder
    private var appearanceSection: some View {
        Section {
            Picker("Theme", selection: $settings.appearance) {
                Text("Light").tag(UserSettings.Appearance.light)
                Text("System").tag(UserSettings.Appearance.system)
                Text("Dark").tag(UserSettings.Appearance.dark)
            }
            .pickerStyle(.segmented)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(AccentTheme.allCases) { theme in
                        let isSelected = settings.effectiveAccentTheme == theme
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                // Tapping a color pins it and turns off daily shuffle.
                                settings.dailyAccentShuffle = false
                                settings.accentTheme = theme
                            }
                        } label: {
                            Circle()
                                .fill(theme.color)
                                .frame(width: 27, height: 27)
                                .overlay {
                                    if isSelected {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                                .padding(3)
                                .overlay {
                                    Circle()
                                        .strokeBorder(
                                            isSelected ? theme.color : .clear,
                                            lineWidth: 2
                                        )
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Toggle("Shuffle Color Daily", isOn: $settings.dailyAccentShuffle)
        } header: {
            Text("Appearance")
        } footer: {
            if settings.dailyAccentShuffle {
                Text("The accent color changes to a new one each day.")
            }
        }
        .listRowBackground(Color(.secondarySystemGroupedBackground))
    }

    // MARK: - About / Feedback

    private let feedbackAddress = "aagrawal207@gmail.com"

    /// Version-stamped subject so replies say which build the note came from.
    private var feedbackSubject: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "Discourse Player Feedback (v\(version))"
    }

    /// A mail app the feedback button can hand off to. `url` is the app-specific
    /// compose deep link; `scheme` is what we probe with canOpenURL to know it's
    /// installed. The default Mail app uses `mailto:` (always available), so it
    /// has no probe scheme and is always offered.
    private struct MailClient: Identifiable {
        let id = UUID()
        let name: String
        let scheme: String?
        let url: URL
    }

    /// Compose links per client, built with the address + version subject. Order
    /// is default Mail first, then popular third-party apps.
    private var mailClients: [MailClient] {
        let to = feedbackAddress
        let subject = feedbackSubject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? feedbackSubject

        func make(_ name: String, _ scheme: String?, _ string: String) -> MailClient? {
            guard let url = URL(string: string) else { return nil }
            return MailClient(name: name, scheme: scheme, url: url)
        }

        return [
            make("Mail", nil, "mailto:\(to)?subject=\(subject)"),
            make("Gmail", "googlegmail", "googlegmail://co?to=\(to)&subject=\(subject)"),
            make("Outlook", "ms-outlook", "ms-outlook://compose?to=\(to)&subject=\(subject)"),
            make("Spark", "readdle-spark", "readdle-spark://compose?recipient=\(to)&subject=\(subject)"),
            make("Yahoo Mail", "ymail", "ymail://mail/compose?to=\(to)&subject=\(subject)"),
        ].compactMap { $0 }
    }

    /// Clients actually installed: the default Mail app (no scheme) plus any
    /// third-party app whose scheme canOpenURL confirms is present.
    private var availableMailClients: [MailClient] {
        mailClients.filter { client in
            guard let scheme = client.scheme else { return true }  // default Mail
            guard let probe = URL(string: "\(scheme)://") else { return false }
            return UIApplication.shared.canOpenURL(probe)
        }
    }

    /// Route the feedback tap: if more than the default Mail app is available,
    /// let the user choose; otherwise open the one option directly.
    private func handleFeedbackTap() {
        let clients = availableMailClients
        if clients.count > 1 {
            showMailClientPicker = true
        } else if let only = clients.first {
            openURL(only.url)
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: "1.5.2")
            LabeledContent("Series", value: "\(Catalog.allSeries.count)")
            LabeledContent("Discourses", value: "\(Catalog.allSeries.reduce(0) { $0 + $1.count })")

            Link(destination: URL(string: "https://buymeacoffee.com/aagrawal207")!) {
                linkRow("Support Development", icon: "cup.and.saucer.fill", tint: Color.accent)
            }

            Link(destination: URL(string: "https://github.com/aagrawal207/OshoDiscourses")!) {
                linkRow("Source Code", icon: "chevron.left.forwardslash.chevron.right")
            }

            Button {
                handleFeedbackTap()
            } label: {
                linkRow("Send Feedback", icon: "envelope")
            }
            .buttonStyle(.plain)
        } header: {
            Text("About")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("This app is an independent player for publicly available audio content hosted at oshoworld.com. Not affiliated with or endorsed by the Osho International Foundation.")
                Text("Support keeps development going — new features, fixes, and upkeep. It's a voluntary thank-you for the app, not a purchase, and unlocks nothing.")
                Text("Your listening progress, bookmarks, and stats sync across your devices through your own iCloud. Everything else stays on this device. No accounts, no servers, no analytics, no tracking.")
            }
            .padding(.top, 8)
        }
        .listRowBackground(Color(.secondarySystemGroupedBackground))
        .confirmationDialog("Send feedback with", isPresented: $showMailClientPicker, titleVisibility: .visible) {
            ForEach(availableMailClients) { client in
                Button(client.name) { openURL(client.url) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Compact About-link row: smaller label, subtle trailing arrow, tighter
    /// height than a default Form row. Shared by all three links so they match.
    private func linkRow(_ title: String, icon: String, tint: Color = .primary) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .font(.subheadline)
                .foregroundStyle(tint)
            Spacer()
            Image(systemName: "arrow.up.right")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

