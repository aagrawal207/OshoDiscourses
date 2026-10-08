import SwiftUI
import UIKit

/// Text the reader copies, shares or drags out of a transcript. Rows are a
/// presentation split, so passages are rejoined the way the source reads.
enum TranscriptPassages {

    /// Selected blocks in reading order. Neighbouring rows of one paragraph
    /// rejoin with their original spacing; anything else starts a new paragraph.
    static func text(for blocks: [TranscriptView.Block]) -> String {
        var result = ""
        var previous: TranscriptView.Block?
        for block in blocks.sorted(by: { $0.ordinal < $1.ordinal }) {
            if let previous {
                let continues = previous.paragraph == block.paragraph && previous.id.index + 1 == block.id.index
                result += continues ? block.gapBefore : "\n\n"
            }
            result += block.text
            previous = block
        }
        return result
    }

    static func shareText(_ text: String, series: String?, number: Int?) -> String {
        guard let series, let number else { return text }
        return "\(text)\n\n— Osho, \(series) #\(number)"
    }

    /// Selection after "Select Up to Here": every row between the selected row
    /// nearest to `target` and `target` itself is added.
    static func extending(_ selection: Set<TranscriptView.Block.ID>, to target: TranscriptView.Block, in blocks: [TranscriptView.Block]) -> Set<TranscriptView.Block.ID> {
        let selectedOrdinals = blocks.filter { selection.contains($0.id) }.map(\.ordinal)
        guard let nearest = selectedOrdinals.min(by: { abs($0 - target.ordinal) < abs($1 - target.ordinal) }) else {
            return selection.union([target.id])
        }
        let range = min(nearest, target.ordinal)...max(nearest, target.ordinal)
        return selection.union(blocks.filter { range.contains($0.ordinal) }.map(\.id))
    }

    /// Whitespace that separated a row from the one before it in its paragraph,
    /// reduced to a single space or line break.
    static func gap(in text: String, between previous: Range<String.Index>?, and next: Range<String.Index>) -> String {
        guard let previous, previous.upperBound <= next.lowerBound else { return "" }
        return text[previous.upperBound..<next.lowerBound].contains("\n") ? "\n" : " "
    }
}

/// Passages shown in a native text view, so the reader can pick exact words
/// with the system handles and copy, share, look up, translate or drag them.
struct TranscriptTextSelectionView: View {
    struct Item: Identifiable {
        let id = UUID()
        let text: String
        let shareText: String
    }

    let item: Item
    let fontSize: CGFloat

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    #if targetEnvironment(macCatalyst)
    private static let hint = "Select words, then copy, share or drag them into another app."
    #else
    private static let hint = "Touch and hold to select words, then copy, share or drag them into another app."
    #endif

    var body: some View {
        NavigationStack {
            SelectableText(text: item.text, fontSize: fontSize)
                .safeAreaInset(edge: .top, spacing: 0) {
                    Text(Self.hint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(.bar)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                }
                .navigationTitle("Select Text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(copied ? "Copied" : "Copy All") {
                            UIPasteboard.general.string = item.text
                            copied = true
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                copied = false
                            }
                        }
                        .accessibilityIdentifier("transcript.selectText.copyAll")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: item.shareText)
                            .labelStyle(.iconOnly)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("transcript.selectText.done")
                    }
                }
                .sensoryFeedback(.success, trigger: copied) { _, new in new }
        }
    }
}

private struct SelectableText: UIViewRepresentable {
    let text: String
    let fontSize: CGFloat

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 32, right: 16)
        view.adjustsFontForContentSizeCategory = false
        // Off by default on iPhone; dragging a selection out is the point here.
        view.textDragInteraction?.isEnabled = true
        view.accessibilityIdentifier = "transcript.selectText.body"
        return view
    }

    final class Coordinator {
        var shown: (text: String, fontSize: CGFloat)?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateUIView(_ view: UITextView, context: Context) {
        // Reassigning the text would drop the reader's selection and scroll position.
        if let shown = context.coordinator.shown, shown.text == text, shown.fontSize == fontSize { return }
        context.coordinator.shown = (text, fontSize)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = fontSize * 0.28
        let attributed = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: fontSize),
            .foregroundColor: UIColor.label,
            .paragraphStyle: style,
        ])
        view.attributedText = attributed
    }
}
