import SwiftUI

struct SettingsView: View {
    @Bindable private var settings = UserSettings.shared

    var body: some View {
        NavigationStack {
            Form {
                listeningStatsSection
                contentSection
                playerSection
                appearanceSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(Color(.systemBackground))
            .navigationTitle("Settings")
            .safeAreaInset(edge: .bottom) {
                Spacer().frame(height: 70)
            }
        }
    }

    // MARK: - Listening Stats

    private var listeningStatsSection: some View {
        Section {
            NavigationLink {
                ListeningStatsView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.accent, in: RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Listening Stats")
                        Text(statsSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listRowBackground(Color(.secondarySystemGroupedBackground))
    }

    private var statsSubtitle: String {
        let stats = ListeningStatsService.shared
        let total = Int(stats.totalAllTime)
        let hrs = total / 3600
        let mins = (total % 3600) / 60
        if hrs > 0 { return "\(hrs)h \(mins)m total" }
        if mins > 0 { return "\(mins)m total" }
        return "Start listening to track time"
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
            Toggle("Noise Reduction", isOn: $settings.noiseReduction)
            Toggle("Smart Download", isOn: $settings.smartDownload)
            Toggle("Smart Delete", isOn: $settings.smartDelete)
        }
        .listRowBackground(Color(.secondarySystemGroupedBackground))
    }

    // MARK: - Appearance

    @ViewBuilder
    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: $settings.appearance) {
                Text("System").tag(UserSettings.Appearance.system)
                Text("Dark").tag(UserSettings.Appearance.dark)
                Text("Light").tag(UserSettings.Appearance.light)
            }
            .pickerStyle(.segmented)
        }
        .listRowBackground(Color(.secondarySystemGroupedBackground))

        Section("Accent Color") {
            HStack(spacing: 10) {
                ForEach(AccentTheme.allCases) { theme in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            settings.accentTheme = theme
                        }
                    } label: {
                        Circle()
                            .fill(theme.color)
                            .frame(width: 30, height: 30)
                            .overlay {
                                if settings.accentTheme == theme {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .padding(3)
                            .overlay {
                                Circle()
                                    .strokeBorder(
                                        settings.accentTheme == theme ? theme.color : .clear,
                                        lineWidth: 2
                                    )
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listRowBackground(Color(.secondarySystemGroupedBackground))
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: "1.2.0")
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
        } header: {
            Text("About")
        } footer: {
            Text("This app is an independent player for publicly available audio content hosted at oshoworld.com. Not affiliated with or endorsed by the Osho International Foundation.")
                .padding(.top, 8)
        }
        .listRowBackground(Color(.secondarySystemGroupedBackground))
    }
}

