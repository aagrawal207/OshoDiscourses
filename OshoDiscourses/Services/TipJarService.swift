import Foundation
import StoreKit

/// Tip jar: consumable In-App Purchases that unlock nothing. App Review
/// (guideline 3.1.1) requires donations to a developer to go through StoreKit
/// rather than an external page, so this is the only way the app can accept
/// support.
///
/// Consumables are not restorable and grant no entitlement, so the whole job
/// is: load products, purchase one, finish the transaction, remember the total
/// for a thank-you line. Unfinished transactions from an interrupted purchase
/// are finished on launch through `Transaction.updates`.
@Observable
@MainActor
final class TipJarService {
    static let shared = TipJarService()

    /// Product ids as configured in App Store Connect, cheapest first.
    static let productIDs = [
        "com.agraabhi.oshodiscourses.tip.small",
        "com.agraabhi.oshodiscourses.tip.medium",
        "com.agraabhi.oshodiscourses.tip.large",
        "com.agraabhi.oshodiscourses.tip.grand",
    ]

    enum PurchaseState: Equatable {
        case idle
        case purchasing(String)
        case thanked
        case failed(String)
    }

    private(set) var products: [Product] = []
    private(set) var loadError: String?
    private(set) var isLoading = false
    private(set) var state: PurchaseState = .idle
    /// Number of tips ever completed on this device, for the thank-you line.
    private(set) var tipCount: Int

    private let defaults: UserDefaults
    private static let tipCountKey = "tipJar.count"
    private var updates: Task<Void, Never>?

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        tipCount = defaults.integer(forKey: Self.tipCountKey)
        updates = Task { [weak self] in
            // Delivers transactions that finished outside a purchase call:
            // Ask to Buy approvals, or a purchase interrupted by a crash.
            for await result in Transaction.updates {
                await self?.handle(result, fromPurchase: false)
            }
        }
    }

    func loadProducts() async {
        guard products.isEmpty, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await Product.products(for: Self.productIDs)
            products = loaded.sorted { $0.price < $1.price }
            loadError = products.isEmpty ? "Tips are not available right now." : nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func purchase(_ product: Product) async {
        guard case .idle = state else { return }
        state = .purchasing(product.id)
        do {
            switch try await product.purchase() {
            case .success(let verification):
                await handle(verification, fromPurchase: true)
            case .pending:
                // Ask to Buy: the transaction arrives through `updates` later.
                state = .idle
            case .userCancelled:
                state = .idle
            @unknown default:
                state = .idle
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func dismissMessage() {
        switch state {
        case .thanked, .failed: state = .idle
        default: break
        }
    }

    private func handle(_ result: VerificationResult<Transaction>, fromPurchase: Bool) async {
        switch result {
        case .verified(let transaction):
            if transaction.revocationDate == nil, Self.productIDs.contains(transaction.productID) {
                tipCount += 1
                defaults.set(tipCount, forKey: Self.tipCountKey)
                state = .thanked
            } else if fromPurchase {
                state = .idle
            }
            await transaction.finish()
        case .unverified(let transaction, let error):
            // Tampered or unsigned; nothing to grant, but leaving it open would
            // make StoreKit resend it forever.
            print("[TipJar] unverified transaction \(transaction.id): \(error)")
            await transaction.finish()
            if fromPurchase { state = .failed("The purchase could not be verified.") }
        }
    }
}
