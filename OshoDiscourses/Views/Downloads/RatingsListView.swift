import SwiftUI

struct RatingsListView: View {
    @State private var ratedDiscourses: [(discourse: CatalogDiscourse, series: SeriesInfo, rating: Int)] = []
    @State private var ratedSeries: [(series: SeriesInfo, rating: Int)] = []

    var body: some View {
        List {
            if !ratedSeries.isEmpty {
                Section("Series") {
                    ForEach(ratedSeries, id: \.series.id) { item in
                        NavigationLink(value: item.series) {
                            HStack(spacing: 12) {
                                SeriesThumbnailView(name: item.series.name, size: 36)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.series.name)
                                        .font(.body)
                                        .lineLimit(1)
                                    Text("\(item.series.count) discourses")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                starsDisplay(item.rating)
                            }
                        }
                    }
                }
                .listRowBackground(Color(.secondarySystemGroupedBackground))
            }

            if !ratedDiscourses.isEmpty {
                Section("Discourses") {
                    ForEach(ratedDiscourses, id: \.discourse.id) { item in
                        NavigationLink(value: item.series) {
                            HStack(spacing: 12) {
                                SeriesThumbnailView(name: item.series.name, size: 36)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.discourse.displayTitle)
                                        .font(.body)
                                        .lineLimit(1)
                                    Text(item.series.name)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                starsDisplay(item.rating)
                            }
                        }
                    }
                }
                .listRowBackground(Color(.secondarySystemGroupedBackground))
            }

            if ratedSeries.isEmpty && ratedDiscourses.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Ratings",
                        systemImage: "star",
                        description: Text("Rate discourses and series to see them here.")
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
        .onAppear { loadRatings() }
    }

    private func starsDisplay(_ count: Int) -> some View {
        HStack(spacing: 1) {
            ForEach(1...count, id: \.self) { _ in
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.yellow)
            }
        }
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
