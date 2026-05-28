import SwiftUI

enum SeriesFilter: String, CaseIterable {
    case all = "All"
    case english = "English"
    case hindi = "Hindi"
    case downloaded = "Downloaded"
}

enum SeriesSort: String, CaseIterable {
    case name = "Name"
    case discourseCount = "Episodes"
}

struct HomeView: View {
    @State private var searchText = ""
    @State private var activeFilter: SeriesFilter = .all
    @State private var activeSort: SeriesSort = .name
    @State private var navigationPath = NavigationPath()
    @Environment(DownloadService.self) private var downloads
    private var settings = UserSettings.shared

    private var visibleSeries: [SeriesInfo] {
        Catalog.allSeries.filter { series in
            if settings.hideHindi && series.language == .hindi { return false }
            if settings.hideEnglish && series.language == .english { return false }
            return true
        }
    }

    private var filteredSeries: [SeriesInfo] {
        var result = visibleSeries

        // Text search
        if !searchText.isEmpty {
            let lower = searchText.lowercased()
            result = result.filter { $0.name.localizedCaseInsensitiveContains(lower) }
        }

        // Filter chips
        switch activeFilter {
        case .all: break
        case .english: result = result.filter { $0.language == .english }
        case .hindi: result = result.filter { $0.language == .hindi }
        case .downloaded:
            result = result.filter { series in
                Catalog.discourses(for: series).contains { downloads.isDownloaded($0.id) }
            }
        }

        // Sort
        switch activeSort {
        case .name: result.sort { $0.name < $1.name }
        case .discourseCount: result.sort { $0.count > $1.count }
        }

        return result
    }

    private var popularEnglish: [SeriesInfo] {
        guard settings.showPopularEnglish && !settings.hideEnglish else { return [] }
        return Catalog.popularEnglish
    }

    private var beginnerEnglish: [SeriesInfo] {
        guard settings.showBeginnerEnglish && !settings.hideEnglish else { return [] }
        return Catalog.beginnerEnglish
    }

    private var popularHindi: [SeriesInfo] {
        guard settings.showPopularHindi && !settings.hideHindi else { return [] }
        return Catalog.popularHindi
    }

    private var beginnerHindi: [SeriesInfo] {
        guard settings.showBeginnerHindi && !settings.hideHindi else { return [] }
        return Catalog.beginnerHindi
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    // Filter and sort bar
                    filterSortBar

                    if searchText.isEmpty && activeFilter == .all {
                        if !popularEnglish.isEmpty {
                            SeriesSectionView(title: "Popular in English", series: popularEnglish)
                        }
                        if !beginnerEnglish.isEmpty {
                            SeriesSectionView(title: "Beginner Friendly (English)", series: beginnerEnglish)
                        }
                        if !popularHindi.isEmpty {
                            SeriesSectionView(title: "Popular in Hindi", series: popularHindi)
                        }
                        if !beginnerHindi.isEmpty {
                            SeriesSectionView(title: "Beginner Friendly (Hindi)", series: beginnerHindi)
                        }
                    }

                    allSeriesSection
                }
                .padding(.top, 8)
            }
            .background(Color(.systemBackground))
            .navigationTitle("Browse")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack {
                        Text("Browse")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("\(Catalog.allSeries.count) series")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search series")
            .navigationDestination(for: SeriesInfo.self) { series in
                SeriesDetailView(seriesInfo: series)
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigateToSeries)) { notification in
                if let series = notification.object as? SeriesInfo {
                    navigationPath = NavigationPath()
                    navigationPath.append(series)
                }
            }
        }
    }

    // MARK: - Filter & Sort Bar

    private var filterSortBar: some View {
        VStack(spacing: 8) {
            // Filter chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SeriesFilter.allCases, id: \.self) { filter in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                activeFilter = activeFilter == filter ? .all : filter
                            }
                        } label: {
                            Text(filter.rawValue)
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(activeFilter == filter ? Color.blue : Color(.tertiarySystemFill))
                                .foregroundStyle(activeFilter == filter ? .white : .primary)
                                .clipShape(Capsule())
                        }
                    }

                    Divider()
                        .frame(height: 20)

                    // Sort picker
                    Menu {
                        ForEach(SeriesSort.allCases, id: \.self) { sort in
                            Button {
                                activeSort = sort
                            } label: {
                                HStack {
                                    Text(sort.rawValue)
                                    if activeSort == sort {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.caption)
                            Text(activeSort.rawValue)
                                .font(.subheadline.weight(.medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color(.tertiarySystemFill))
                        .foregroundStyle(.primary)
                        .clipShape(Capsule())
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    @ViewBuilder
    private var allSeriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("All Series")
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(filteredSeries.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            LazyVStack(spacing: 0) {
                ForEach(filteredSeries) { series in
                    NavigationLink(value: series) {
                        SeriesRowView(series: series)
                    }
                    .buttonStyle(.plain)

                    Divider()
                        .background(Color.white.opacity(0.1))
                        .padding(.leading, 76)
                }
            }
        }
    }
}

// MARK: - Horizontal Section

private struct SeriesSectionView: View {
    let title: String
    let series: [SeriesInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(.primary)
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(series) { item in
                        NavigationLink(value: item) {
                            SeriesCardView(series: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

// MARK: - Series Card

private struct SeriesCardView: View {
    let series: SeriesInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SeriesThumbnailView(name: series.name, size: 140)

            Text(series.name)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(width: 140, alignment: .leading)

            Text("\(series.count) discourses")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Series Row

private struct SeriesRowView: View {
    let series: SeriesInfo

    var body: some View {
        HStack(spacing: 12) {
            SeriesThumbnailView(name: series.name, size: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text(series.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text("\(series.count) discourses")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(series.language == .hindi ? "Hindi" : "English")
                .font(.caption2)
                .fontWeight(.medium)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.blue.opacity(0.2))
                .foregroundStyle(.blue)
                .clipShape(Capsule())

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}

// MARK: - Thumbnail View

struct SeriesThumbnailView: View {
    let name: String
    let size: CGFloat

    private var gradientColors: [Color] {
        let hash = abs(name.hashValue)
        let hue1 = Double(hash % 360) / 360.0
        let hue2 = Double((hash / 360) % 360) / 360.0
        return [
            Color(hue: hue1, saturation: 0.6, brightness: 0.5),
            Color(hue: hue2, saturation: 0.7, brightness: 0.3)
        ]
    }

    private var initials: String {
        String(name.prefix(2)).uppercased()
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(
                LinearGradient(
                    colors: gradientColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .overlay {
                Text(initials)
                    .font(.system(size: size * 0.3, weight: .bold))
                    .foregroundStyle(.primary)
            }
    }
}
