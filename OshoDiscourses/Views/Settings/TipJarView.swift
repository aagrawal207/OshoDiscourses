import SwiftUI
import StoreKit

struct TipJarView: View {
    @Environment(\.dismiss) private var dismiss
    private let tips: TipJarService
    private var settings = UserSettings.shared

    init(tips: TipJarService = .shared) {
        self.tips = tips
    }

    private var accent: Color { settings.effectiveAccentTheme.color }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "cup.and.saucer.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(accent)
                        Text("Osho Talks is free and has no ads or tracking. If it has become part of your days, an optional tip helps me keep improving it.")
                        Text("Tips are one-time purchases through Apple. They unlock no features or content. Every feature stays free for everyone.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
                .listRowBackground(Color(.secondarySystemGroupedBackground))

                Section {
                    if tips.isLoading {
                        HStack { ProgressView(); Text("Loading tips…").foregroundStyle(.secondary) }
                    }
                    ForEach(tips.products, id: \.id) { product in
                        tipRow(product)
                    }
                    if let error = tips.loadError {
                        Text(error).foregroundStyle(.secondary)
                        Button("Try Again") {
                            Task { await tips.loadProducts() }
                        }
                        .disabled(tips.isLoading || tips.isPurchasing)
                        .accessibilityIdentifier("tipJar.retry")
                    }
                } footer: {
                    if tips.tipCount > 0 {
                        Text(tips.tipCount == 1 ? "One tip recorded on this device. Thank you." : "\(tips.tipCount) tips recorded on this device. Thank you.")
                    }
                }
                .listRowBackground(Color(.secondarySystemGroupedBackground))
            }
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Support Development")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await tips.loadProducts() }
            // Pending stays inline so a later approval can present its own confirmation.
            .safeAreaInset(edge: .bottom) {
                if tips.state == .pending {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Tip pending", systemImage: "clock")
                            .font(.headline)
                        Text("Your purchase is pending with the App Store. It may need approval, such as Ask to Buy. You don't need to try again.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Got It") { tips.dismissMessage() }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial)
                }
            }
            .alert(purchaseMessage?.title ?? "", isPresented: Binding(
                get: { purchaseMessage != nil },
                set: { if !$0 { tips.dismissMessage() } }
            ), presenting: purchaseMessage) { _ in
                Button("OK") { tips.dismissMessage() }
            } message: { message in
                Text(message.body)
            }
        }
    }

    private var purchaseMessage: (title: String, body: String)? {
        switch tips.state {
        case .thanked:
            return ("Thank you", "Your tip keeps this app going. Enjoy the talks.")
        case .failed(let message):
            return ("Couldn't confirm tip", message)
        case .idle, .purchasing, .pending:
            return nil
        }
    }

    private func tipRow(_ product: Product) -> some View {
        Button {
            Task { await tips.purchase(product) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(product.displayName).foregroundStyle(.primary)
                    if !product.description.isEmpty {
                        Text(product.description).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if tips.state == .purchasing(product.id) {
                    ProgressView()
                } else {
                    Text(product.displayPrice)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(accent.opacity(0.15), in: Capsule())
                        .foregroundStyle(accent)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!tips.canPurchase)
        .accessibilityIdentifier(product.id)
    }
}
