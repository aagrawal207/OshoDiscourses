import SwiftUI

struct SettingsView: View {
    @Bindable private var settings = UserSettings.shared
    @Environment(AudioPlayerService.self) private var player

    var body: some View {
        NavigationStack {
            Form {
                contentSection
                playerSection
                noiseReductionSection
                appearanceSection
                moreAppsSection
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
            HStack(spacing: 6) {
                Text("Noise Reduction")
                Text("BETA")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.accent.opacity(0.15), in: Capsule())
            }
        } footer: {
            Text("Beta: this feature is still being tuned and results vary by recording — some talks clean up nicely, others may sound softened or artifacted. Reduces background hiss and hum during playback using on-device speech filtering. Light keeps speech clearest, Strong removes the most noise. You can also long-press the Denoise button in the player to change strength. If it doesn't sound right, just turn it off.")
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

    // MARK: - More Apps

    /// Other apps by the same developer. Icons are bundled (downscaled from
    /// each app's own asset catalog) so the rows render instantly offline;
    /// links open the App Store product pages.
    private struct DeveloperApp: Identifiable {
        let name: String
        let subtitle: String
        let iconAsset: String
        let storeURL: URL
        var id: String { name }
    }

    private static let developerApps: [DeveloperApp] = [
        DeveloperApp(
            name: "Bruce",
            subtitle: "Workout tracker",
            iconAsset: "BruceIcon",
            storeURL: URL(string: "https://apps.apple.com/app/bruce-workout-tracker/id6770409619")!
        ),
        DeveloperApp(
            name: "Drop",
            subtitle: "The falling ball",
            iconAsset: "DropIcon",
            storeURL: URL(string: "https://apps.apple.com/app/drop-the-falling-ball/id6789235254")!
        ),
    ]

    private var moreAppsSection: some View {
        Section {
            ForEach(Self.developerApps) { app in
                Link(destination: app.storeURL) {
                    HStack(spacing: 12) {
                        Image(app.iconAsset)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 40, height: 40)
                            // App Store icon curvature ≈ 22.4% of the side.
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                            Text(app.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("My Other Apps")
        }
        .listRowBackground(Color(.secondarySystemGroupedBackground))
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.6.0")
            LabeledContent("Series", value: "\(Catalog.allSeries.count)")
            LabeledContent("Discourses", value: "\(Catalog.allSeries.reduce(0) { $0 + $1.count })")

            Link(destination: URL(string: "https://buymeacoffee.com/aagrawal207")!) {
                linkRow("Support Development", icon: "cup.and.saucer.fill", tint: Color.accent)
            }

            Link(destination: URL(string: "https://github.com/aagrawal207/OshoDiscourses")!) {
                linkRow("Source Code", icon: "chevron.left.forwardslash.chevron.right")
            }

            Link(destination: URL(string: "mailto:agraabhi@gmail.com?subject=Osho%20Talks%20Feedback")!) {
                linkRow("Send Feedback", icon: "envelope")
            }
        } header: {
            Text("About")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Acknowledgements: All discourses are copyright OSHO International Foundation. Audio is served from oshoworld.com.")
                Text("This app is an independent player for publicly available audio content hosted at oshoworld.com. Not affiliated with or endorsed by the Osho International Foundation.")
                Text("Support keeps development going — new features, fixes, and upkeep. It's a voluntary thank-you for the app, not a purchase, and unlocks nothing.")
                Text("Your listening progress, bookmarks, and stats sync across your devices through your own iCloud. Everything else stays on this device. No accounts, no servers, no analytics, no tracking.")
            }
            .padding(.top, 8)
        }
        .listRowBackground(Color(.secondarySystemGroupedBackground))
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

