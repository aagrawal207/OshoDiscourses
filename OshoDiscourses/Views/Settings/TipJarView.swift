#if DEBUG
import SwiftUI
import StoreKit

/// Tip jar sheet: three consumable tips with prices from the App Store, a
/// short note on what they are (a thank-you, not a purchase of anything), and
/// a thank-you once one goes through.
struct TipJarView: View {
    @Environment(\.dismiss) private var dismiss
    private var tips = TipJarService.shared
    private var settings = UserSettings.shared

    private var accent: Color { settings.effectiveAccentTheme.color }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "cup.and.saucer.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(accent)
                        Text("Osho Talks is free, has no ads and collects nothing. If it has become part of your days, a small tip helps me keep improving it.")
                        Text("A tip unlocks nothing and is not refundable. Every feature stays free for everyone.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
                .listRowBackground(Color(.secondarySystemGroupedBackground))

                Section {
                    if tips.isLoading && tips.products.isEmpty {
                        HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
                    } else if let error = tips.loadError, tips.products.isEmpty {
                        Text(error).foregroundStyle(.secondary)
                    } else {
                        ForEach(tips.products, id: \.id) { product in
                            tipRow(product)
                        }
                    }
                } footer: {
                    if tips.tipCount > 0 {
                        Text(tips.tipCount == 1 ? "You have tipped once. Thank you." : "You have tipped \(tips.tipCount) times. Thank you.")
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
            .alert("Thank you", isPresented: Binding(get: { tips.state == .thanked }, set: { _ in tips.dismissMessage() })) {
                Button("You're welcome") { tips.dismissMessage() }
            } message: {
                Text("Your tip keeps this app going. Enjoy the talks.")
            }
            .alert("Tip did not go through", isPresented: Binding(
                get: { if case .failed = tips.state { return true } else { return false } },
                set: { _ in tips.dismissMessage() }
            )) {
                Button("OK") { tips.dismissMessage() }
            } message: {
                if case .failed(let message) = tips.state { Text(message) }
            }
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
        .disabled(tips.state != .idle)
    }
}
#endif
