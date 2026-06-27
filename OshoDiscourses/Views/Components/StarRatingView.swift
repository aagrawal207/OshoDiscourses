import SwiftUI

struct StarRatingView: View {
    let rating: Int
    let maxRating: Int = 5
    var size: CGFloat = 16
    var onRate: ((Int) -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...maxRating, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .font(.system(size: size))
                    .foregroundStyle(star <= rating ? .yellow : .secondary.opacity(0.4))
                    .onTapGesture {
                        if star == rating {
                            onRate?(0)
                        } else {
                            onRate?(star)
                        }
                    }
            }
        }
    }
}

struct CompactRatingBadge: View {
    let rating: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill")
                .font(.system(size: 10))
                .foregroundStyle(.yellow)
            Text("\(rating)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.yellow.opacity(0.1))
        .clipShape(Capsule())
    }
}
