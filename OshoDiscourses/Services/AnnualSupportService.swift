import Foundation
import StoreKit
import os

@Observable
@MainActor
final class AnnualSupportService {
    static let shared = AnnualSupportService(defaults: .standard, observeTransactions: true)
    static let subscriptionGroupID = "22466252"
    static let productIDs = [
        "com.agraabhi.oshodiscourses.support.annual5",
        "com.agraabhi.oshodiscourses.support.annual10",
        "com.agraabhi.oshodiscourses.support.annual15",
    ]

    struct Status {
        let productID: String
        let state: Product.SubscriptionInfo.RenewalState
    }

    typealias PurchaseState = TipJarService.PurchaseState
    typealias StatusLoader = @MainActor ([Product]) async throws -> [Status]

    private(set) var products: [Product] = []
    private(set) var loadError: String?
    private(set) var statusError: String?
    private(set) var currentProductID: String?
    private(set) var restoreMessage: String?
    private(set) var state: PurchaseState = .idle
    private(set) var isLoading = false
    private(set) var isRefreshingStatus = false
    private(set) var isPurchasing = false
    private(set) var isRestoring = false
    private(set) var statusIsCurrent = false
    private(set) var pendingProductID: String?

    var isBusy: Bool { isLoading || isRefreshingStatus || isPurchasing || isRestoring }
    var canPurchase: Bool { !isBusy && statusIsCurrent && currentProductID == nil && pendingProductID == nil && state == .idle }

    @ObservationIgnored private let loadStatuses: StatusLoader
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var updates: Task<Void, Never>?
    @ObservationIgnored private var recovery: Task<Void, Never>?
    @ObservationIgnored private var statusUpdates: Task<Void, Never>?
    @ObservationIgnored private var finishes: [UInt64: Task<Void, Never>] = [:]
    @ObservationIgnored private var statusWaiters: [CheckedContinuation<Void, Never>] = []
    private var needsStatusRefresh = false
    private static let log = Logger(subsystem: "com.agraabhi.oshodiscourses", category: "AnnualSupport")
    private static let pendingProductKey = "annualSupport.pendingProductID"

    init(defaults: UserDefaults? = nil, observeTransactions: Bool = false, loadStatuses: @escaping StatusLoader = AnnualSupportService.storeStatuses) {
        self.defaults = defaults
        self.loadStatuses = loadStatuses
        if let pending = defaults?.string(forKey: Self.pendingProductKey), Self.productIDs.contains(pending) {
            pendingProductID = pending
            state = .pending
        }
        guard observeTransactions else { return }
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                guard !Task.isCancelled else { return }
                await self?.handleUpdate(result)
            }
        }
        recovery = Task { [weak self] in
            for await result in Transaction.unfinished {
                guard !Task.isCancelled else { return }
                await self?.handleUpdate(result)
            }
        }
        statusUpdates = Task { [weak self] in
            for await status in Product.SubscriptionInfo.Status.updates {
                guard !Task.isCancelled else { return }
                let transaction = status.transaction.unsafePayloadValue
                guard Self.isAnnualSupport(productID: transaction.productID, type: transaction.productType) else { continue }
                await self?.refreshStatus()
            }
        }
    }

    deinit {
        updates?.cancel()
        recovery?.cancel()
        statusUpdates?.cancel()
    }

    static func isAnnualSupport(productID: String, type: Product.ProductType) -> Bool {
        productIDs.contains(productID) && type == .autoRenewable
    }

    static func isAnnualSupport(_ product: Product) -> Bool {
        isAnnualSupport(productID: product.id, type: product.type)
            && product.subscription?.subscriptionPeriod.unit == .year
            && product.subscription?.subscriptionPeriod.value == 1
    }

    func loadProducts(
        using load: @MainActor () async throws -> [Product] = { try await Product.products(for: AnnualSupportService.productIDs) }
    ) async {
        guard !isLoading, !isPurchasing, !isRestoring else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            products = try await load().filter(Self.isAnnualSupport).sorted { $0.price < $1.price }
            if products.count < Self.productIDs.count {
                loadError = "Some yearly support options aren't available right now. Please try again later."
                Self.log.info("Product load outcome=partial")
            } else {
                Self.log.info("Product load outcome=available")
            }
            await refreshStatus()
        } catch {
            products = []
            statusIsCurrent = false
            loadError = "Couldn't load yearly support from the App Store. Check your connection and try again."
            Self.log.error("Product load outcome=failed")
        }
    }

    func refreshStatus() async {
        if isRefreshingStatus {
            needsStatusRefresh = true
            await withCheckedContinuation { statusWaiters.append($0) }
            return
        }
        isRefreshingStatus = true
        defer {
            isRefreshingStatus = false
            let waiters = statusWaiters
            statusWaiters = []
            for waiter in waiters { waiter.resume() }
        }
        repeat {
            needsStatusRefresh = false
            statusIsCurrent = false
            do {
                let statuses = try await loadStatuses(products)
                currentProductID = Self.currentProduct(in: statuses)
                statusError = nil
                statusIsCurrent = true
                if currentProductID != nil { clearDeclinedRequest() }
                if state == .thanked, currentProductID == nil { state = .idle }
                Self.log.info("Status refresh outcome=verified")
            } catch {
                statusError = "Couldn't check your existing yearly support. Try again before starting a subscription."
                Self.log.error("Status refresh outcome=failed")
            }
        } while needsStatusRefresh
    }

    static func currentProduct(in statuses: [Status]) -> String? {
        statuses.first {
            [.subscribed, .inGracePeriod, .inBillingRetryPeriod].contains($0.state)
        }?.productID
    }

    private static func storeStatuses(_ products: [Product]) async throws -> [Status] {
        let groups = Set(products.compactMap { $0.subscription?.subscriptionGroupID })
        guard groups.count <= 1 else { throw StoreKitError.notAvailableInStorefront }
        let group = groups.first ?? subscriptionGroupID
        return try await Product.SubscriptionInfo.status(for: group).map { status in
            guard case .verified(let transaction) = status.transaction,
                  case .verified = status.renewalInfo else { throw StoreKitError.notEntitled }
            return Status(productID: transaction.productID, state: status.state)
        }
    }

    func purchase(_ product: Product) async {
        await purchase(productID: product.id, type: product.type) {
            switch try await product.purchase() {
            case .success(let result):
                return await self.purchaseState(for: result, productID: product.id)
            case .pending: return .pending
            case .userCancelled: return .idle
            @unknown default: return .failed("Couldn't confirm your subscription. Check your App Store subscriptions before trying again.")
            }
        }
    }

    func purchase(
        productID: String, type: Product.ProductType,
        operation: @MainActor () async throws -> PurchaseState
    ) async {
        guard canPurchase else {
            Self.log.info("Purchase outcome=blocked")
            return
        }
        guard Self.isAnnualSupport(productID: productID, type: type) else { return }
        isPurchasing = true
        restoreMessage = nil
        state = .purchasing(productID)
        defer { isPurchasing = false }
        do {
            state = try await operation()
        } catch StoreKitError.userCancelled {
            state = .idle
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failed("Couldn't confirm your subscription. Check your App Store subscriptions before trying again.")
        }
        if state == .pending, currentProductID != nil { state = .idle }
        if state == .pending {
            pendingProductID = productID
            defaults?.set(productID, forKey: Self.pendingProductKey)
        }
        let outcome: String
        switch state {
        case .thanked: outcome = "completed"
        case .pending: outcome = "pending"
        case .idle: outcome = "cancelled"
        default: outcome = "failed"
        }
        Self.log.info("Purchase outcome=\(outcome, privacy: .public)")
    }

    func purchaseState<T: TipJarTransaction>(for result: VerificationResult<T>, productID: String) async -> PurchaseState {
        let confirmed = await finish(result, expectedProductID: productID)
        await refreshStatus()
        return confirmed && statusIsCurrent && currentProductID != nil
            ? .thanked
            : .failed("Couldn't verify your subscription. Check your App Store subscriptions before trying again.")
    }

    func handleUpdate<T: TipJarTransaction>(_ result: VerificationResult<T>) async {
        guard Self.isAnnualSupport(productID: result.unsafePayloadValue.productID, type: result.unsafePayloadValue.productType) else { return }
        await finish(result)
        await refreshStatus()
    }

    @discardableResult
    func finish<T: TipJarTransaction>(_ result: VerificationResult<T>, expectedProductID: String? = nil) async -> Bool {
        guard case .verified(let transaction) = result,
              Self.isAnnualSupport(productID: transaction.productID, type: transaction.productType),
              expectedProductID == nil || expectedProductID == transaction.productID else {
            Self.log.error("Transaction outcome=unverified_or_unsupported")
            return false
        }
        if let task = finishes[transaction.id] {
            await task.value
        } else {
            let task = Task { await transaction.finish() }
            finishes[transaction.id] = task
            await task.value
            finishes[transaction.id] = nil
        }
        Self.log.info("Transaction outcome=finished")
        return transaction.revocationDate == nil
    }

    func restore(using sync: @MainActor () async throws -> Void = { try await AppStore.sync() }) async {
        guard !isBusy, state == .idle else { return }
        isRestoring = true
        restoreMessage = nil
        defer { isRestoring = false }
        do {
            try await sync()
            await refreshStatus()
            if statusIsCurrent {
                restoreMessage = currentProductID == nil ? "No current yearly support subscription was found." : "Your yearly support subscription is restored. Thank you."
            }
            Self.log.info("Restore outcome=completed")
        } catch StoreKitError.userCancelled {
            Self.log.info("Restore outcome=cancelled")
        } catch {
            state = .failed("Couldn't restore your subscription. Please try again later.")
            Self.log.error("Restore outcome=failed")
        }
    }

    func dismissMessage() {
        switch state {
        case .thanked, .pending, .failed: state = .idle
        default: break
        }
    }

    func clearDeclinedRequest() {
        if pendingProductID != nil { Self.log.info("Pending request outcome=cleared") }
        pendingProductID = nil
        defaults?.removeObject(forKey: Self.pendingProductKey)
        if state == .pending { state = .idle }
    }
}
