import SwiftUI

struct SettingsView: View {
    @Bindable private var settings = UserSettings.shared

    var body: some View {
        NavigationStack {
            Form {
                languageSection
                browseSectionsSection
                playbackSection
                downloadsSection
                appearanceSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(Color(.systemBackground))
            .navigationTitle("Settings")
        }
    }

    private var languageSection: some View {
        Section("Language") {
            Picker("Show", selection: $settings.languageFilter) {
                Text("Both").tag(LanguageFilter.both)
                Text("English").tag(LanguageFilter.english)
                Text("Hindi").tag(LanguageFilter.hindi)
            }
            .pickerStyle(.segmented)
        }
        .listRowBackground(Color(.secondarySystemGroupedBackground))
    }

    private var browseSectionsSection: some View {
        Section("Browse Sections") {
            Toggle("Popular in English", isOn: $settings.showPopularEnglish)
                .disabled(settings.hideEnglish)
            Toggle("Beginner Friendly (English)", isOn: $settings.showBeginnerEnglish)
                .disabled(settings.hideEnglish)
            Toggle("Popular in Hindi", isOn: $settings.showPopularHindi)
                .disabled(settings.hideHindi)
            Toggle("Beginner Friendly (Hindi)", isOn: $settings.showBeginnerHindi)
                .disabled(settings.hideHindi)
        }
        .listRowBackground(Color(.secondarySystemGroupedBackground))
    }

    private var playbackSection: some View {
        Section("Playback") {
            Toggle("Auto-Play Next", isOn: $settings.autoPlayNext)
        }
        .listRowBackground(Color(.secondarySystemGroupedBackground))
    }

    private var downloadsSection: some View {
        Section("Downloads") {
            Toggle("Smart Download", isOn: $settings.smartDownload)
            Toggle("Smart Delete", isOn: $settings.smartDelete)
        }
        .listRowBackground(Color(.secondarySystemGroupedBackground))
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: $settings.appearance) {
                Text("System").tag(UserSettings.Appearance.system)
                Text("Dark").tag(UserSettings.Appearance.dark)
                Text("Light").tag(UserSettings.Appearance.light)
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 8) {
                Text("Accent Color")
                    .font(.subheadline)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(AccentTheme.allCases) { theme in
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    settings.accentTheme = theme
                                }
                            } label: {
                                Circle()
                                    .fill(theme.color)
                                    .frame(width: 32, height: 32)
                                    .overlay {
                                        if settings.accentTheme == theme {
                                            Image(systemName: "checkmark")
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                                    .overlay {
                                        Circle()
                                            .strokeBorder(
                                                settings.accentTheme == theme ? theme.color : .clear,
                                                lineWidth: 2
                                            )
                                            .frame(width: 40, height: 40)
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .listRowBackground(Color(.secondarySystemGroupedBackground))
    }

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Version")
                Spacer()
                Text("1.0.0")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Series")
                Spacer()
                Text("\(Catalog.allSeries.count)")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Total Discourses")
                Spacer()
                Text("\(Catalog.allSeries.reduce(0) { $0 + $1.count })")
                    .foregroundStyle(.secondary)
            }
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
        }
        .listRowBackground(Color(.secondarySystemGroupedBackground))
    }
}
