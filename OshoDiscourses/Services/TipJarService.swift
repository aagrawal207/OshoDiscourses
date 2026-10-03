import Foundation
import StoreKit
import os

// StoreKit transactions cannot be constructed in unit tests. Keep their native
// verification result and expose only the fields needed by the tip policy.
@MainActor
protocol TipJarTransaction: Sendable {
    var id: UInt64 { get }
    var productID: String { get }
    var productType: Product.ProductType { get }
    var revocationDate: Date? { get }
    func finish() async
}

extension StoreKit.Transaction: TipJarTransaction {}

/// Consumable tips grant no entitlement; only verified transactions are acknowledged.
@Observable
@MainActor
final class TipJarService {
    static let shared = TipJarService(defaults: .standard, observeTransactions: true)

    static let productIDs = [
        "com.agraabhi.oshodiscourses.tip.small",
        "com.agraabhi.oshodiscourses.tip.medium",
        "com.agraabhi.oshodiscourses.tip.large",
        "com.agraabhi.oshodiscourses.tip.grand",
        "com.agraabhi.oshodiscourses.tip.patron",
    ]

    enum PurchaseState: Equatable {
        case idle
        case purchasing(String)
        case thanked
        case pending
        case failed(String)
    }

    enum TransactionSource: String {
        case purchase, update, recovery
    }

    enum TransactionOutcome: String {
        case completed, duplicate, unverified, revoked, unsupported, unexpectedProduct
    }

    private(set) var products: [Product] = []
    private(set) var loadError: String?
    private(set) var isLoading = false
    private(set) var isPurchasing = false
    private(set) var state: PurchaseState = .idle

    var canPurchase: Bool { !isLoading && !isPurchasing && state == .idle }
    var tipCount: Int { legacyTipCount + recordedTips.values.filter { $0 }.count }

    private let defaults: UserDefaults
    private let legacyTipCount: Int
    // False tombstones prevent an older delivery from re-crediting a refunded tip.
    private var recordedTips: [String: Bool]
    private static let recordedTipsKey = "tipJar.transactions"
    private static let log = Logger(subsystem: "com.agraabhi.oshodiscourses", category: "TipJar")
    private static let verificationMessage = "The App Store purchase could not be verified. Check your purchase history before trying again."
    private static let confirmationMessage = "We couldn't confirm your tip. Check your App Store purchase history before trying again."
    @ObservationIgnored private var updates: Task<Void, Never>?
    @ObservationIgnored private var recovery: Task<Void, Never>?
    @ObservationIgnored private var finishes: [UInt64: Task<Void, Never>] = [:]

    init(defaults: UserDefaults, observeTransactions: Bool = false) {
        self.defaults = defaults
        // The old counter has no transaction IDs, so retain it as a migration baseline.
        legacyTipCount = max(0, defaults.integer(forKey: "tipJar.count"))
        recordedTips = defaults.dictionary(forKey: Self.recordedTipsKey) as? [String: Bool] ?? [:]
        guard observeTransactions else { return }
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                guard !Task.isCancelled else { return }
                await self?.handle(result, source: .update)
            }
        }
        recovery = Task { [weak self] in
            for await result in Transaction.unfinished {
                guard !Task.isCancelled else { return }
                await self?.handle(result, source: .recovery)
            }
        }
    }

    deinit {
        updates?.cancel()
        recovery?.cancel()
    }

    static func isTip(productID: String, type: Product.ProductType) -> Bool {
        productIDs.contains(productID) && type == .consumable
    }

    func loadProducts(
        using load: @MainActor () async throws -> [Product] = { try await Product.products(for: TipJarService.productIDs) }
    ) async {
        guard !isLoading, !isPurchasing else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let loaded = try await load()
            products = loaded.filter { Self.isTip(productID: $0.id, type: $0.type) }
                .sorted { $0.price < $1.price }
            if products.isEmpty {
                loadError = "Tips aren't available in the App Store right now. Please try again later."
                Self.log.info("Product load outcome=unavailable")
            } else if products.count < Self.productIDs.count {
                loadError = "Some tips aren't available right now. You can choose an available tip or try again."
                Self.log.info("Product load outcome=partial")
            } else {
                Self.log.info("Product load outcome=available")
            }
        } catch is CancellationError {
            loadError = "Loading was interrupted. Please try again."
            Self.log.debug("Product load outcome=cancelled")
        } catch {
            products = []
            loadError = "Couldn't load tips from the App Store. Check your connection and try again."
            Self.log.error("Product load outcome=failed")
        }
    }

    func purchase(_ product: Product) async {
        await purchase(productID: product.id, type: product.type) {
            await self.purchaseState(for: try await product.purchase(), productID: product.id)
        }
    }

    func purchase(
        productID: String, type: Product.ProductType,
        operation: @MainActor () async throws -> PurchaseState
    ) async {
        guard canPurchase else {
            Self.log.debug("Purchase outcome=busy")
            return
        }
        guard Self.isTip(productID: productID, type: type) else {
            state = .failed("This tip is not available. Please reload the tip jar.")
            Self.log.error("Purchase outcome=unsupported")
            return
        }
        isPurchasing = true
        state = .purchasing(productID)
        defer { isPurchasing = false }
        do {
            state = try await operation()
        } catch StoreKitError.userCancelled {
            state = .idle
            Self.log.info("Purchase outcome=cancelled")
        } catch is CancellationError {
            state = .idle
            Self.log.info("Purchase outcome=interrupted")
        } catch Product.PurchaseError.purchaseNotAllowed {
            state = .failed("In-app purchases aren't allowed on this device.")
            Self.log.info("Purchase outcome=restricted")
        } catch Product.PurchaseError.productUnavailable {
            state = .failed("This tip is currently unavailable in the App Store. Please try again later.")
            Self.log.info("Purchase outcome=unavailable")
        } catch {
            state = .failed(Self.confirmationMessage)
            Self.log.error("Purchase outcome=failed")
        }
    }

    func purchaseState(for result: Product.PurchaseResult, productID: String) async -> PurchaseState {
        switch result {
        case .success(let verification):
            return await purchaseState(for: verification, productID: productID)
        case .pending:
            Self.log.info("Purchase outcome=pending")
            return .pending
        case .userCancelled:
            Self.log.info("Purchase outcome=cancelled")
            return .idle
        @unknown default:
            Self.log.error("Purchase outcome=unknown")
            return .failed(Self.confirmationMessage)
        }
    }

    func purchaseState<T: TipJarTransaction>(for result: VerificationResult<T>, productID: String) async -> PurchaseState {
        switch await handle(result, source: .purchase, expectedProductID: productID) {
        case .completed, .duplicate:
            return .thanked
        case .unverified:
            return .failed(Self.verificationMessage)
        case .revoked:
            return .failed("This purchase was refunded or revoked. No tip was recorded.")
        case .unsupported, .unexpectedProduct:
            return .failed(Self.confirmationMessage)
        }
    }

    func dismissMessage() {
        switch state {
        case .thanked, .pending, .failed: state = .idle
        default: break
        }
    }

    @discardableResult
    func handle<T: TipJarTransaction>(
        _ result: VerificationResult<T>, source: TransactionSource, expectedProductID: String? = nil
    ) async -> TransactionOutcome {
        guard case .verified(let transaction) = result else {
            Self.log.error("Transaction source=\(source.rawValue, privacy: .public) outcome=unverified")
            // Leave unverified purchases unfinished so a later verified delivery can recover them.
            if source != .purchase, !isPurchasing,
               Self.isTip(productID: result.unsafePayloadValue.productID, type: result.unsafePayloadValue.productType) {
                state = .failed(Self.verificationMessage)
            }
            return .unverified
        }
        guard Self.isTip(productID: transaction.productID, type: transaction.productType) else {
            Self.log.error("Transaction source=\(source.rawValue, privacy: .public) outcome=unsupported")
            return .unsupported
        }
        guard expectedProductID == nil || expectedProductID == transaction.productID else {
            Self.log.error("Transaction source=\(source.rawValue, privacy: .public) outcome=unexpectedProduct")
            return .unexpectedProduct
        }

        let id = String(transaction.id)
        let outcome: TransactionOutcome
        if transaction.revocationDate != nil || recordedTips[id] == false {
            recordedTips[id] = false
            outcome = .revoked
        } else if recordedTips[id] == true {
            outcome = .duplicate
        } else {
            recordedTips[id] = true
            outcome = .completed
        }
        // Persist before awaiting finish: purchase, updates, and recovery can overlap.
        defaults.set(recordedTips, forKey: Self.recordedTipsKey)
        Self.log.info("Transaction source=\(source.rawValue, privacy: .public) outcome=\(outcome.rawValue, privacy: .public)")

        // A background approval must not replace another purchase's progress or result.
        if source != .purchase, !isPurchasing {
            if outcome == .completed { state = .thanked }
            if outcome == .revoked, state == .thanked { state = .idle }
        }

        if let finish = finishes[transaction.id] {
            await finish.value
        } else {
            let finish = Task { await transaction.finish() }
            finishes[transaction.id] = finish
            await finish.value
            finishes[transaction.id] = nil
            Self.log.debug("Transaction finish=completed")
        }
        // A refund may arrive while finish is suspended.
        return recordedTips[id] == false ? .revoked : outcome
    }
}
