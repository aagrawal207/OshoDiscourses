import SwiftUI

enum SeriesFilter: Hashable {
    case all
    case english
    case hindi
    case downloaded
    case theme(String)

    var label: String {
        switch self {
        case .all: return "All"
        case .english: return "English"
        case .hindi: return "Hindi"
        case .downloaded: return "Downloaded"
        case .theme(let name): return name.capitalized
        }
    }
}

enum SeriesSortField: String, CaseIterable {
    case name = "Name"
    case episodes = "Episodes"
}

enum SortDirection {
    case ascending, descending

    var icon: String {
        self == .ascending ? "chevron.up" : "chevron.down"
    }

    mutating func toggle() {
        self = self == .ascending ? .descending : .ascending
    }
}

struct LibraryView: View {
    @State private var searchText = ""
    @State private var activeFilter: SeriesFilter = .all
    @State private var sortField: SeriesSortField = .name
    @State private var sortDirection: SortDirection = .ascending
    @Environment(DownloadService.self) private var downloads
    private var settings = UserSettings.shared

    /// Themes shown as filter chips only when shared by at least this many
    /// currently-visible series — keeps one-off themes out of the bar.
    private let minSeriesPerThemeFilter = 3

    private var visibleSeries: [SeriesInfo] {
        Catalog.allSeries.filter { series in
            if settings.hideHindi && series.language == .hindi { return false }
            if settings.hideEnglish && series.language == .english { return false }
            return true
        }
    }

    /// Filters that actually have entries given the visible series + downloads.
    /// "All" is always present; language/downloaded/theme chips appear only when
    /// at least one matching series exists.
    private var availableFilters: [SeriesFilter] {
        var filters: [SeriesFilter] = [.all]

        let hasEnglish = visibleSeries.contains { $0.language == .english }
        let hasHindi = visibleSeries.contains { $0.language == .hindi }
        // Only offer a language chip when both languages are present — if only
        // one is visible, the chip would be redundant with "All".
        if hasEnglish && hasHindi {
            filters.append(.english)
            filters.append(.hindi)
        }

        let downloadedSeriesIDs = Set(
            downloads.downloadedIDs.compactMap { Catalog.discourseLookup[$0]?.series.id }
        )
        if visibleSeries.contains(where: { downloadedSeriesIDs.contains($0.id) }) {
            filters.append(.downloaded)
        }

        // Count theme occurrences across visible series; keep the shared ones.
        var themeCounts: [String: Int] = [:]
        for series in visibleSeries {
            for theme in SeriesMetadata.themes(for: series.name) {
                let key = theme.lowercased()
                if key == "hindi" || key == "english" { continue }  // redundant w/ language
                themeCounts[key, default: 0] += 1
            }
        }
        let themeFilters = themeCounts
            .filter { $0.value >= minSeriesPerThemeFilter }
            .keys
            .sorted()
            .map { SeriesFilter.theme($0) }
        filters.append(contentsOf: themeFilters)

        return filters
    }

    private var filteredSeries: [SeriesInfo] {
        var result = visibleSeries

        if !searchText.isEmpty {
            let lower = searchText.lowercased()
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(lower) ||
                SeriesMetadata.searchableText(for: $0.name).localizedCaseInsensitiveContains(lower)
            }
        }

        switch activeFilter {
        case .all: break
        case .english: result = result.filter { $0.language == .english }
        case .hindi: result = result.filter { $0.language == .hindi }
        case .downloaded:
            let downloadedSeriesIDs = Set(
                downloads.downloadedIDs.compactMap { Catalog.discourseLookup[$0]?.series.id }
            )
            result = result.filter { downloadedSeriesIDs.contains($0.id) }
        case .theme(let theme):
            result = result.filter { series in
                SeriesMetadata.themes(for: series.name).contains { $0.lowercased() == theme }
            }
        }

        switch (sortField, sortDirection) {
        case (.name, .ascending): result.sort { $0.name < $1.name }
        case (.name, .descending): result.sort { $0.name > $1.name }
        case (.episodes, .ascending): result.sort { $0.count < $1.count }
        case (.episodes, .descending): result.sort { $0.count > $1.count }
        }

        return result
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    filterSortBar
                        .padding(.bottom, 8)

                    ForEach(filteredSeries) { series in
                        NavigationLink(value: series) {
                            SeriesRowView(series: series)
                        }
                        .buttonStyle(.plain)

                        Divider()
                            .padding(.leading, 72)
                    }
                }
                .padding(.bottom, 70)
            }
            .background(Color(.systemBackground))
            .navigationTitle("Library")
            .searchable(text: $searchText, prompt: "Search by name or topic")
            .navigationDestination(for: SeriesInfo.self) { series in
                SeriesDetailView(seriesInfo: series)
            }
            .onAppear { resetFilterIfUnavailable() }
            .onChange(of: settings.languageFilter) { resetFilterIfUnavailable() }
            .onChange(of: downloads.downloadedIDs) { resetFilterIfUnavailable() }
        }
    }

    /// If the active filter is no longer offered (language hidden, last download
    /// removed, etc.), fall back to All so the list isn't stuck empty.
    private func resetFilterIfUnavailable() {
        if !availableFilters.contains(activeFilter) {
            activeFilter = .all
        }
    }

    private var filterSortBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(availableFilters, id: \.self) { filter in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            activeFilter = activeFilter == filter ? .all : filter
                        }
                    } label: {
                        Text(filter.label)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(activeFilter == filter ? Color.accent : Color(.tertiarySystemFill))
                            .foregroundStyle(activeFilter == filter ? .white : .secondary)
                            .clipShape(Capsule())
                    }
                }

                Menu {
                    ForEach(SeriesSortField.allCases, id: \.self) { field in
                        Button {
                            if sortField == field {
                                sortDirection.toggle()
                            } else {
                                sortField = field
                                sortDirection = .ascending
                            }
                        } label: {
                            HStack {
                                Text(field.rawValue)
                                if sortField == field {
                                    Image(systemName: sortDirection.icon)
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: sortDirection == .ascending ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9))
                        Text(sortField.rawValue)
                            .font(.caption.weight(.medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(.tertiarySystemFill))
                    .foregroundStyle(.secondary)
                    .clipShape(Capsule())
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
    }
}

// MARK: - Series Row

private struct SeriesRowView: View {
    let series: SeriesInfo

    var body: some View {
        HStack(spacing: 12) {
            SeriesThumbnailView(name: series.name, size: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text(series.name)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text("\(series.count) discourses")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)

                    Text(series.language == .hindi ? "Hindi" : "English")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.quaternary)
        }
        .padding(.horizontal)
        .padding(.vertical, 9)
    }
}
