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
        Section("Player & Downloads") {
            Toggle("Auto-Play Next", isOn: $settings.autoPlayNext)
            Toggle("Smart Download", isOn: $settings.smartDownload)
            Toggle("Smart Delete", isOn: $settings.smartDelete)
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
                Text("System").tag(UserSettings.Appearance.system)
                Text("Dark").tag(UserSettings.Appearance.dark)
                Text("Light").tag(UserSettings.Appearance.light)
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

    // MARK: - About

    /// mailto with the app version prefilled in the subject. Falls back to a
    /// plain mailto if encoding ever fails. Tapping does nothing if no mail
    /// account is configured, which iOS handles gracefully.
    private var feedbackURL: URL {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let subject = "Discourse Player Feedback (v\(version))"
        let encoded = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subject
        return URL(string: "mailto:aagrawal207@gmail.com?subject=\(encoded)")
            ?? URL(string: "mailto:aagrawal207@gmail.com")!
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: "1.4.0")
            LabeledContent("Series", value: "\(Catalog.allSeries.count)")
            LabeledContent("Discourses", value: "\(Catalog.allSeries.reduce(0) { $0 + $1.count })")

            Link(destination: URL(string: "https://github.com/aagrawal207/OshoDiscourses")!) {
                HStack {
                    Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Link(destination: feedbackURL) {
                HStack {
                    Label("Send Feedback", systemImage: "envelope")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("About")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("This app is an independent player for publicly available audio content hosted at oshoworld.com. Not affiliated with or endorsed by the Osho International Foundation.")
                Text("Your data — playback positions, downloads, and settings — stays on this device and syncs only through your own iCloud account. No accounts, no analytics, no tracking.")
            }
            .padding(.top, 8)
        }
        .listRowBackground(Color(.secondarySystemGroupedBackground))
    }
}

