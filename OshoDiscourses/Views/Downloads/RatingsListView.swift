import SwiftUI

struct RatingsListView: View {
    @State private var ratedDiscourses: [(discourse: CatalogDiscourse, series: SeriesInfo, rating: Int)] = []
    @State private var ratedSeries: [(series: SeriesInfo, rating: Int)] = []

    var body: some View {
        List {
            if !ratedSeries.isEmpty {
                Section {
                    ForEach(ratedSeries, id: \.series.id) { item in
                        NavigationLink(value: item.series) {
                            HStack(spacing: 12) {
                                SeriesThumbnailView(name: item.series.name, size: 40)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.series.name)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                    Text("\(item.series.count) discourses")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                CompactRatingBadge(rating: item.rating)
                            }
                        }
                    }
                } header: {
                    Text("Series (\(ratedSeries.count))")
                }
                .listRowBackground(Color(.secondarySystemGroupedBackground))
            }

            if !ratedDiscourses.isEmpty {
                Section {
                    ForEach(ratedDiscourses, id: \.discourse.id) { item in
                        NavigationLink(value: item.series) {
                            HStack(spacing: 12) {
                                SeriesThumbnailView(name: item.series.name, size: 40)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.discourse.displayTitle)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                    Text(item.series.name)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                CompactRatingBadge(rating: item.rating)
                            }
                        }
                    }
                } header: {
                    Text("Discourses (\(ratedDiscourses.count))")
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
        .navigationDestination(for: SeriesInfo.self) { series in
            SeriesDetailView(seriesInfo: series)
        }
        .safeAreaInset(edge: .bottom) {
            Spacer().frame(height: 70)
        }
        .onAppear { loadRatings() }
    }

    private func loadRatings() {
        let ratings = RatingService.shared

        ratedSeries = Catalog.allSeries.compactMap { series in
            let r = ratings.seriesRating(for: series.id)
            guard r > 0 else { return nil }
            return (series: series, rating: r)
        }
        .sorted { $0.rating > $1.rating }

        ratedDiscourses = Catalog.allSeries.flatMap { series in
            Catalog.discourses(for: series).compactMap { disc in
                let r = ratings.discourseRating(for: disc.id)
                guard r > 0 else { return nil }
                return (discourse: disc, series: series, rating: r)
            }
        }
        .sorted { $0.rating > $1.rating }
    }
}
