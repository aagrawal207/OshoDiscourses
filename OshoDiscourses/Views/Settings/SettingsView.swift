import SwiftUI
#if canImport(WatchConnectivity) && !targetEnvironment(macCatalyst)
import WatchConnectivity
#endif

struct SettingsView: View {
    @Bindable private var settings = UserSettings.shared
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.horizontalSizeClass) private var sizeClass
    // Transaction listening outlives the support sheet, including delayed approvals.
    private let tips = TipJarService.shared
    @State private var showTipJar = false
    @ScaledMetric(relativeTo: .subheadline) private var miniPlayerClearance: CGFloat = 70
    #if DEBUG
    /// `-debugTipJar` opens the tip sheet on launch for layout checks.
    private var debugTipJar: Bool { ProcessInfo.processInfo.arguments.contains("-debugTipJar") }
    #endif

    var body: some View {
        NavigationStack {
            Form {
                contentSection
                playerSection
                audioEnhancementSection
                #if canImport(WatchConnectivity) && !targetEnvironment(macCatalyst)
                appleWatchSection
                #endif
                appearanceSection
                moreAppsSection
                aboutSection
            }
            .readableScrollColumn(sizeClass, maxWidth: 680)
            .sheet(isPresented: $showTipJar) { TipJarView(tips: tips) }
            #if DEBUG
            .task {
                guard debugTipJar else { return }
                try? await Task.sleep(for: .seconds(2))   // after the tab switch
                showTipJar = true
            }
            #endif
            // Use the Form's native grouped background so sections render as
            // rounded cards: light-gray page + white cards in light mode, true
            // black + dark-gray cards in dark mode. (An earlier systemBackground
            // override flattened the cards to invisible in light mode.)
            .navigationTitle("Settings")
        }
        // The floating player sits above the Settings navigation container.
        .safeAreaInset(edge: .bottom) {
            if player.currentTrackId != nil {
                Spacer().frame(height: miniPlayerClearance)
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

    // MARK: - Apple Watch

    #if canImport(WatchConnectivity) && !targetEnvironment(macCatalyst)
    @ViewBuilder
    private var appleWatchSection: some View {
        // iPad and Mac can't pair a Watch; WCSession reports that directly.
        if WCSession.isSupported(), UIDevice.current.userInterfaceIdiom == .phone {
            Section {
                NavigationLink {
                    AppleWatchView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "applewatch")
                            .foregroundStyle(Color.accent)
                        Text("Apple Watch")
                    }
                }
                .accessibilityIdentifier("settings.appleWatch")
            } footer: {
                Text("Control playback from your wrist, or keep discourses on Apple Watch to listen without your iPhone.")
            }
            .listRowBackground(Color(.secondarySystemGroupedBackground))
        }
    }
    #endif

    // MARK: - Audio Enhancement

    private var audioEnhancementSection: some View {
        Section {
            NavigationLink {
                AudioEnhancementView(bottomScrollClearance: player.currentTrackId == nil ? nil : miniPlayerClearance + 16)
                    .environment(player)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "waveform")
                        .foregroundStyle(Color.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("DeNoise")
                        Text(player.isNoiseReductionEnabled
                             ? player.noiseReductionMode.displayName
                             : "Noise reduction and volume boost")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Text(player.isNoiseReductionEnabled ? "On" : "Off")
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("settings.audioEnhancement")
        } header: {
            Text("Sound")
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
                            // Color.primary/.secondary, not .primary/.secondary.
                            // The bare hierarchical styles resolve against the
                            // enclosing Link's tint, so they came out accent
                            // coloured; the absolute Colors stay label black.
                            Text(app.name)
                                .font(.subheadline)
                                .foregroundStyle(Color.primary)
                            Text(app.subtitle)
                                .font(.caption)
                                .foregroundStyle(Color.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
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

            Button { showTipJar = true } label: {
                linkRow("Support Development", icon: "cup.and.saucer.fill", tint: settings.effectiveAccentTheme.color, trailing: "chevron.right")
            }

            Link(destination: URL(string: "https://github.com/aagrawal207/OshoDiscourses")!) {
                linkRow("Source Code", icon: "chevron.left.forwardslash.chevron.right")
            }

            Link(destination: URL(string: "mailto:aagrawal207@gmail.com?subject=Osho%20Talks%20Feedback")!) {
                linkRow("Send Feedback", icon: "envelope")
            }
        } header: {
            Text("About")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Acknowledgements: All discourses are copyright OSHO International Foundation. Audio is served from oshoworld.com.")
                Text("Noise reduction uses RNNoise (Xiph.Org, BSD 3-Clause) and DeepFilterNet by Hendrik Schröter (MIT/Apache-2.0).")
                Text("This app is an independent player for publicly available audio content hosted at oshoworld.com. Not affiliated with or endorsed by the Osho International Foundation.")
                Text("Your listening progress, bookmarks, and stats sync between your devices through your own iCloud. Everything else stays on your phone. There are no accounts, no servers, and no tracking of any kind.")
            }
            .padding(.top, 8)
        }
        .listRowBackground(Color(.secondarySystemGroupedBackground))
    }

    /// Compact About-link row: smaller label, subtle trailing arrow, tighter
    /// height than a default Form row. Shared by the About links so they match.
    private func linkRow(_ title: String, icon: String, tint: Color = .primary, trailing: String = "arrow.up.right") -> some View {
        HStack {
            Label(title, systemImage: icon)
                .font(.subheadline)
                .foregroundStyle(tint)
            Spacer()
            Image(systemName: trailing)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
