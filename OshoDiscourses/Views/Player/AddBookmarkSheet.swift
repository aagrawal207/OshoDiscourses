import SwiftUI

struct AddBookmarkSheet: View {
    @Environment(\.dismiss) private var dismiss
    let timestamp: TimeInterval
    let discourseID: String
    let seriesName: String
    let title: String
    let onSaved: () -> Void

    @State private var note = ""
    @State private var selectedCategory: BookmarkCategory = .relisten
    @State private var customCategoryText = ""

    private let bookmarks = BookmarkService.shared

    init(timestamp: TimeInterval, discourseID: String, seriesName: String, title: String, onSaved: @escaping () -> Void) {
        self.timestamp = timestamp
        self.discourseID = discourseID
        self.seriesName = seriesName
        self.title = title
        self.onSaved = onSaved
    }

    private var formattedTime: String {
        let mins = Int(timestamp) / 60
        let secs = Int(timestamp) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Image(systemName: "clock")
                            .foregroundStyle(.blue)
                        Text("Timestamp")
                        Spacer()
                        Text(formattedTime)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    HStack {
                        Image(systemName: "music.note")
                            .foregroundStyle(.blue)
                        Text(title)
                            .lineLimit(1)
                    }
                }

                Section("Category") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 10) {
                        ForEach(BookmarkCategory.allCases) { category in
                            Button {
                                selectedCategory = category
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: category.icon)
                                        .font(.caption)
                                    Text(category.rawValue)
                                        .font(.subheadline)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(
                                    selectedCategory == category
                                        ? Color.blue.opacity(0.2)
                                        : Color(.tertiarySystemFill)
                                )
                                .foregroundStyle(selectedCategory == category ? .blue : .primary)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)

                    if selectedCategory == .custom {
                        TextField("Custom category name", text: $customCategoryText)
                    }
                }

                Section("Note (optional)") {
                    TextField("What caught your attention?", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("Add Bookmark")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        bookmarks.add(
                            discourseID: discourseID,
                            seriesName: seriesName,
                            title: title,
                            timestamp: timestamp,
                            note: note,
                            category: selectedCategory,
                            customCategory: selectedCategory == .custom ? customCategoryText : nil
                        )
                        dismiss()
                        onSaved()
                    }
                }
            }
        }
    }
}
