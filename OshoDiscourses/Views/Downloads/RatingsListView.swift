import SwiftUI

struct RatingsListView: View {
    @State private var ratedDiscourses: [(discourse: CatalogDiscourse, series: SeriesInfo, rating: Int)] = []
    @State private var ratedSeries: [(series: SeriesInfo, rating: Int)] = []
    @State private var sortHighFirst = true

    var body: some View {
        List {
            if !ratedSeries.isEmpty {
                Section {
                    ForEach(sortedSeries, id: \.series.id) { item in
                        NavigationLink(value: item.series) {
                            seriesRow(item)
                        }
                    }
                } header: {
                    HStack {
                        Text("Series")
                        Spacer()
                        Text("\(ratedSeries.count) rated")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .listRowBackground(Color(.secondarySystemGroupedBackground))
            }

            if !ratedDiscourses.isEmpty {
                Section {
                    ForEach(sortedDiscourses, id: \.discourse.id) { item in
                        NavigationLink(value: item.series) {
                            discourseRow(item)
                        }
                    }
                } header: {
                    HStack {
                        Text("Discourses")
                        Spacer()
                        Text("\(ratedDiscourses.count) rated")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .listRowBackground(Color(.secondarySystemGroupedBackground))
            }

            if ratedSeries.isEmpty && ratedDiscourses.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Ratings Yet",
                        systemImage: "star",
                        description: Text("Long-press any discourse to rate it, or tap the stars in a series header.")
                    )
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .navigationTitle("My Ratings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    sortHighFirst.toggle()
                } label: {
                    Image(systemName: sortHighFirst ? "arrow.down" : "arrow.up")
                }
            }
        }
        .navigationDestination(for: SeriesInfo.self) { series in
            SeriesDetailView(seriesInfo: series)
        }
        .safeAreaInset(edge: .bottom) {
            Spacer().frame(height: 70)
        }
        .onAppear { loadRatings() }
    }

    // MARK: - Rows

    private func seriesRow(_ item: (series: SeriesInfo, rating: Int)) -> some View {
        HStack(spacing: 12) {
            SeriesThumbnailView(name: item.series.name, size: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.series.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 2) {
                    Text("\(item.series.count) discourses")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(item.series.language == .hindi ? "Hindi" : "English")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            StarRatingView(rating: item.rating, size: 12)
        }
        .padding(.vertical, 2)
    }

    private func discourseRow(_ item: (discourse: CatalogDiscourse, series: SeriesInfo, rating: Int)) -> some View {
        HStack(spacing: 12) {
            SeriesThumbnailView(name: item.series.name, size: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.discourse.displayTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                Text(item.series.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            StarRatingView(rating: item.rating, size: 12)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Sorting

    private var sortedSeries: [(series: SeriesInfo, rating: Int)] {
        sortHighFirst
            ? ratedSeries.sorted { $0.rating > $1.rating }
            : ratedSeries.sorted { $0.rating < $1.rating }
    }

    private var sortedDiscourses: [(discourse: CatalogDiscourse, series: SeriesInfo, rating: Int)] {
        sortHighFirst
            ? ratedDiscourses.sorted { $0.rating > $1.rating }
            : ratedDiscourses.sorted { $0.rating < $1.rating }
    }

    // MARK: - Data

    private func loadRatings() {
        let ratings = RatingService.shared

        ratedSeries = Catalog.allSeries.compactMap { series in
            let r = ratings.seriesRating(for: series.id)
            guard r > 0 else { return nil }
            return (series: series, rating: r)
        }

        ratedDiscourses = Catalog.allSeries.flatMap { series in
            Catalog.discourses(for: series).compactMap { disc in
                let r = ratings.discourseRating(for: disc.id)
                guard r > 0 else { return nil }
                return (discourse: disc, series: series, rating: r)
            }
        }
    }
}
