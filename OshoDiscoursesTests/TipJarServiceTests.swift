import Foundation
import StoreKit
import Testing
@testable import OshoDiscourses

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct TipJarServiceTests {
    private var small: String { TipJarService.productIDs[0] }
    private var medium: String { TipJarService.productIDs[1] }

    @Test func onlyIntendedConsumablesAreEligible() {
        for id in TipJarService.productIDs {
            #expect(TipJarService.isTip(productID: id, type: .consumable))
            for type in [Product.ProductType.nonConsumable, .autoRenewable, .nonRenewable] {
                #expect(!TipJarService.isTip(productID: id, type: type))
            }
        }
        #expect(!TipJarService.isTip(productID: "unrelated.product", type: .consumable))
    }

    @Test func emptyCatalogCanBeRetried() async {
        await withService { tips, _ in
            var loads = 0
            for _ in 0..<2 {
                await tips.loadProducts {
                    loads += 1
                    return []
                }
                #expect(tips.products.isEmpty)
                #expect(tips.loadError != nil)
                #expect(!tips.isLoading)
                #expect(tips.tipCount == 0)
            }
            #expect(loads == 2)
        }
    }

    @Test func failedAndCancelledCatalogLoadsReleaseRetryGate() async {
        await withService { tips, _ in
            await tips.loadProducts { throw URLError(.notConnectedToInternet) }
            #expect(tips.loadError != nil)
            #expect(tips.products.isEmpty)
            #expect(!tips.isLoading)

            await tips.loadProducts {
                #expect(tips.loadError == nil)
                throw CancellationError()
            }
            #expect(tips.loadError != nil)
            #expect(!tips.isLoading)

            var retried = false
            await tips.loadProducts {
                retried = true
                return []
            }
            #expect(retried)
        }
    }

    @Test func productLoadingBlocksOverlappingLoadsAndPurchases() async {
        await withService { tips, _ in
            let entered = TipTestGate()
            let release = TipTestGate()
            let loading = Task {
                await tips.loadProducts {
                    entered.open()
                    await release.wait()
                    return []
                }
            }
            await entered.wait()
            #expect(tips.isLoading)
            #expect(!tips.canPurchase)

            var secondLoad = false
            await tips.loadProducts {
                secondLoad = true
                return []
            }
            var purchased = false
            await tips.purchase(productID: small, type: .consumable) {
                purchased = true
                return await tips.purchaseState(for: .pending, productID: small)
            }
            #expect(!secondLoad)
            #expect(!purchased)
            release.open()
            await loading.value
            #expect(!tips.isLoading)
        }
    }

    @Test func verifiedPurchasePersistsBeforeFinishAndThanksAfterward() async {
        await withService { tips, defaults in
            let transaction = TestTipTransaction()
            let entered = TipTestGate()
            let release = TipTestGate()
            transaction.onFinish = {
                entered.open()
                await release.wait()
            }
            let buying = Task { await purchase(.verified(transaction), using: tips) }
            await entered.wait()

            #expect(tips.tipCount == 1)
            #expect(TipJarService(defaults: defaults).tipCount == 1)
            #expect(tips.state == .purchasing(small))
            #expect(tips.isPurchasing)
            #expect(!tips.canPurchase)
            tips.dismissMessage()
            #expect(tips.state == .purchasing(small))

            release.open()
            await buying.value
            #expect(transaction.finishCalls == 1)
            #expect(tips.state == .thanked)
            #expect(!tips.isPurchasing)
            var duplicatePurchase = false
            await tips.purchase(productID: small, type: .consumable) {
                duplicatePurchase = true
                return .pending
            }
            #expect(!duplicatePurchase)
            #expect(tips.tipCount == 1)
            tips.dismissMessage()
            #expect(tips.canPurchase)
        }
    }

    @Test(arguments: [TipJarService.TransactionSource.update, .recovery])
    func duplicateDeliveriesDoNotCountOrThankTwice(source: TipJarService.TransactionSource) async {
        await withService { tips, defaults in
            let transaction = TestTipTransaction()
            #expect(await tips.handle(.verified(transaction), source: source) == .completed)
            #expect(tips.state == .thanked)
            tips.dismissMessage()

            #expect(await tips.handle(.verified(transaction), source: source) == .duplicate)
            #expect(tips.state == .idle)
            #expect(tips.tipCount == 1)
            #expect(transaction.finishCalls == 2)

            let relaunched = TipJarService(defaults: defaults)
            #expect(await relaunched.handle(.verified(transaction), source: .recovery) == .duplicate)
            #expect(relaunched.tipCount == 1)
            #expect(relaunched.state == .idle)
            #expect(transaction.finishCalls == 3)
        }
    }

    @Test func separateTipsForTheSameProductAreCountedSeparately() async {
        await withService { tips, _ in
            let first = TestTipTransaction(id: 1)
            let second = TestTipTransaction(id: 2)
            await purchase(.verified(first), using: tips)
            tips.dismissMessage()
            await purchase(.verified(second), using: tips)
            #expect(tips.tipCount == 2)
            #expect(first.finishCalls == 1)
            #expect(second.finishCalls == 1)
            #expect(tips.state == .thanked)
        }
    }

    @Test func pendingPurchaseWaitsForVerifiedApproval() async {
        await withService { tips, _ in
            await purchase(.pending, using: tips)
            #expect(tips.state == .pending)
            #expect(tips.tipCount == 0)
            #expect(!tips.isPurchasing)
            tips.dismissMessage()

            let approval = TestTipTransaction()
            await tips.handle(.verified(approval), source: .update)
            #expect(tips.state == .thanked)
            #expect(tips.tipCount == 1)
            #expect(approval.finishCalls == 1)
        }
    }

    @Test func userCancellationDoesNotConfirmOrFailPurchase() async {
        await withService { tips, _ in
            await purchase(.userCancelled, using: tips)
            #expect(tips.state == .idle)
            #expect(tips.canPurchase)
            #expect(tips.tipCount == 0)

            await tips.purchase(productID: small, type: .consumable) { throw StoreKitError.userCancelled }
            #expect(tips.state == .idle)
            #expect(tips.canPurchase)
            #expect(tips.tipCount == 0)

            await tips.purchase(productID: small, type: .consumable) { throw CancellationError() }
            #expect(tips.state == .idle)
            #expect(tips.canPurchase)
            #expect(tips.tipCount == 0)
        }
    }

    @Test(arguments: [Product.PurchaseError.productUnavailable, .purchaseNotAllowed])
    func unavailableAndRestrictedPurchasesDoNotCount(error: Product.PurchaseError) async {
        await withService { tips, _ in
            await tips.purchase(productID: small, type: .consumable) { throw error }
            guard case .failed = tips.state else {
                Issue.record("Expected a failed purchase")
                return
            }
            #expect(tips.tipCount == 0)
            #expect(!tips.isPurchasing)
            tips.dismissMessage()
            #expect(tips.canPurchase)
        }
    }

    @Test func failedPurchaseCanBeRetriedWithoutExposingRawError() async {
        await withService { tips, _ in
            let error = NSError(domain: "private-purchase-payload", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "private-purchase-payload"])
            await tips.purchase(productID: small, type: .consumable) { throw error }
            guard case .failed(let message) = tips.state else {
                Issue.record("Expected a failed purchase")
                return
            }
            #expect(!message.contains("private-purchase-payload"))
            #expect(tips.tipCount == 0)
            #expect(!tips.isPurchasing)
            tips.dismissMessage()
            await purchase(.userCancelled, using: tips)
            #expect(tips.state == .idle)
        }
    }

    @Test func unverifiedPurchaseIsNotCountedOrFinishedAndCanRecover() async {
        await withService { tips, _ in
            let transaction = TestTipTransaction()
            await purchase(.unverified(transaction, .invalidSignature), using: tips)
            guard case .failed = tips.state else {
                Issue.record("An unverified purchase must not report success")
                return
            }
            #expect(tips.tipCount == 0)
            #expect(transaction.finishCalls == 0)
            tips.dismissMessage()

            await tips.handle(.verified(transaction), source: .recovery)
            #expect(tips.tipCount == 1)
            #expect(tips.state == .thanked)
            #expect(transaction.finishCalls == 1)
        }
    }

    @Test(arguments: [TipJarService.TransactionSource.update, .recovery])
    func unverifiedBackgroundDeliveryIsNotFinished(source: TipJarService.TransactionSource) async {
        await withService { tips, _ in
            let transaction = TestTipTransaction()
            let outcome = await tips.handle(.unverified(transaction, .invalidDeviceVerification), source: source)
            #expect(outcome == .unverified)
            #expect(transaction.finishCalls == 0)
            #expect(tips.tipCount == 0)
            guard case .failed = tips.state else {
                Issue.record("Expected a verification failure for the pending tip")
                return
            }
        }
    }

    @Test func unrelatedAndNonconsumableTransactionsAreNotFinished() async {
        await withService { tips, _ in
            for transaction in [
                TestTipTransaction(productID: "unrelated.product"),
                TestTipTransaction(productType: .nonConsumable),
                TestTipTransaction(productType: .autoRenewable),
            ] {
                #expect(await tips.handle(.verified(transaction), source: .update) == .unsupported)
                #expect(transaction.finishCalls == 0)
                #expect(tips.tipCount == 0)
                #expect(tips.state == .idle)

                await purchase(.verified(transaction), using: tips)
                guard case .failed = tips.state else {
                    Issue.record("An unsupported transaction must not confirm a purchase")
                    return
                }
                #expect(transaction.finishCalls == 0)
                #expect(tips.tipCount == 0)
                tips.dismissMessage()
            }
            let unrelated = TestTipTransaction(productID: "unrelated.product")
            await tips.handle(.unverified(unrelated, .invalidSignature), source: .update)
            #expect(tips.state == .idle)
            #expect(unrelated.finishCalls == 0)
        }
    }

    @Test func unsupportedProductsNeverStartPurchase() async {
        await withService { tips, _ in
            for (id, type) in [(small, Product.ProductType.nonConsumable), ("unrelated.product", .consumable)] {
                var called = false
                await tips.purchase(productID: id, type: type) {
                    called = true
                    return .pending
                }
                #expect(!called)
                #expect(tips.tipCount == 0)
                guard case .failed = tips.state else {
                    Issue.record("An unsupported product must be rejected")
                    return
                }
                tips.dismissMessage()
            }
        }
    }

    @Test func anotherProductsTransactionCannotConfirmPurchase() async {
        await withService { tips, _ in
            let transaction = TestTipTransaction(productID: medium)
            await purchase(.verified(transaction), using: tips)
            guard case .failed = tips.state else {
                Issue.record("A different product's transaction must not confirm the requested tip")
                return
            }
            #expect(tips.tipCount == 0)
            #expect(transaction.finishCalls == 0)
            tips.dismissMessage()

            await tips.handle(.verified(transaction), source: .update)
            #expect(tips.tipCount == 1)
            #expect(transaction.finishCalls == 1)
        }
    }

    @Test func revokedPurchaseIsFinishedWithoutCreditOrThanks() async {
        await withService { tips, _ in
            let transaction = TestTipTransaction(revocationDate: Date())
            await purchase(.verified(transaction), using: tips)
            #expect(tips.tipCount == 0)
            #expect(transaction.finishCalls == 1)
            guard case .failed = tips.state else {
                Issue.record("A revoked purchase must not report success")
                return
            }
        }
    }

    @Test func refundRemovesCreditAndSurvivesStaleReplayAfterRelaunch() async {
        await withService { tips, defaults in
            let transaction = TestTipTransaction()
            await tips.handle(.verified(transaction), source: .update)
            #expect(tips.tipCount == 1)

            let refund = TestTipTransaction(revocationDate: Date())
            #expect(await tips.handle(.verified(refund), source: .update) == .revoked)
            #expect(tips.tipCount == 0)
            #expect(tips.state == .idle)
            #expect(refund.finishCalls == 1)

            let relaunched = TipJarService(defaults: defaults)
            #expect(await relaunched.handle(.verified(transaction), source: .recovery) == .revoked)
            #expect(relaunched.tipCount == 0)
            #expect(relaunched.state == .idle)
        }
    }

    @Test func purchaseAndUpdateShareFinishAndCreditOnlyOnce() async {
        await withService { tips, _ in
            let transaction = TestTipTransaction()
            let finishEntered = TipTestGate()
            let finishRelease = TipTestGate()
            transaction.onFinish = {
                finishEntered.open()
                await finishRelease.wait()
            }
            let update = Task { await tips.handle(.verified(transaction), source: .update) }
            await finishEntered.wait()
            tips.dismissMessage()

            let purchaseEntered = TipTestGate()
            let buying = Task {
                await tips.purchase(productID: small, type: .consumable) {
                    purchaseEntered.open()
                    return await tips.purchaseState(for: .verified(transaction), productID: small)
                }
            }
            await purchaseEntered.wait()
            #expect(transaction.finishCalls == 1)
            #expect(tips.tipCount == 1)
            #expect(tips.isPurchasing)

            finishRelease.open()
            await buying.value
            #expect(await update.value == .completed)
            #expect(transaction.finishCalls == 1)
            #expect(tips.tipCount == 1)
            #expect(tips.state == .thanked)
        }
    }

    @Test(arguments: [false, true])
    func backgroundApprovalDoesNotUnlockOrReplaceAnotherPurchase(cancelled: Bool) async {
        await withService { tips, _ in
            let entered = TipTestGate()
            let release = TipTestGate()
            let buying = Task {
                await tips.purchase(productID: medium, type: .consumable) {
                    entered.open()
                    await release.wait()
                    let result: Product.PurchaseResult = cancelled ? .userCancelled : .pending
                    return await tips.purchaseState(for: result, productID: medium)
                }
            }
            await entered.wait()

            let approval = TestTipTransaction()
            await tips.handle(.verified(approval), source: .update)
            #expect(tips.tipCount == 1)
            #expect(approval.finishCalls == 1)
            #expect(tips.state == .purchasing(medium))

            let unverified = TestTipTransaction(id: 2, productID: medium)
            await tips.handle(.unverified(unverified, .invalidSignature), source: .update)
            #expect(unverified.finishCalls == 0)
            #expect(tips.state == .purchasing(medium))
            tips.dismissMessage()
            #expect(!tips.canPurchase)

            var secondPurchase = false
            await tips.purchase(productID: small, type: .consumable) {
                secondPurchase = true
                return .pending
            }
            var loaded = false
            await tips.loadProducts {
                loaded = true
                return []
            }
            #expect(!secondPurchase)
            #expect(!loaded)

            release.open()
            await buying.value
            #expect(tips.state == (cancelled ? .idle : .pending))
            #expect(!tips.isPurchasing)
        }
    }

    @Test func refundDuringFinishCannotReportPurchaseSuccess() async {
        await withService { tips, _ in
            let transaction = TestTipTransaction()
            let entered = TipTestGate()
            let release = TipTestGate()
            transaction.onFinish = {
                entered.open()
                await release.wait()
            }
            let buying = Task { await purchase(.verified(transaction), using: tips) }
            await entered.wait()

            let refundEntered = TipTestGate()
            let refund = TestTipTransaction(revocationDate: Date())
            let refunding = Task {
                refundEntered.open()
                return await tips.handle(.verified(refund), source: .update)
            }
            await refundEntered.wait()
            #expect(tips.tipCount == 0)
            release.open()
            await buying.value
            #expect(await refunding.value == .revoked)
            #expect(transaction.finishCalls == 1)
            #expect(refund.finishCalls == 0)
            guard case .failed = tips.state else {
                Issue.record("A refund during finish must suppress the success message")
                return
            }
        }
    }

    @Test func legacyCountIsPreservedWithoutRecountingNewTips() async {
        await withService { _, defaults in
            defaults.set(2, forKey: "tipJar.count")
            let tips = TipJarService(defaults: defaults)
            let transaction = TestTipTransaction()
            #expect(tips.tipCount == 2)
            await purchase(.verified(transaction), using: tips)
            #expect(tips.tipCount == 3)

            let relaunched = TipJarService(defaults: defaults)
            await relaunched.handle(.verified(transaction), source: .recovery)
            #expect(relaunched.tipCount == 3)
            #expect(relaunched.state == .idle)
        }
    }

    private func purchase(_ result: Product.PurchaseResult, using tips: TipJarService) async {
        await tips.purchase(productID: small, type: .consumable) {
            await tips.purchaseState(for: result, productID: small)
        }
    }

    private func purchase(_ result: VerificationResult<TestTipTransaction>, using tips: TipJarService) async {
        await tips.purchase(productID: small, type: .consumable) {
            await tips.purchaseState(for: result, productID: small)
        }
    }

    private func withService(_ body: @MainActor (TipJarService, UserDefaults) async -> Void) async {
        let suite = "TipJarServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        await body(TipJarService(defaults: defaults), defaults)
    }
}

@MainActor
private final class TestTipTransaction: TipJarTransaction {
    let id: UInt64
    let productID: String
    let productType: Product.ProductType
    let revocationDate: Date?
    var finishCalls = 0
    var onFinish: @MainActor () async -> Void = {}

    init(
        id: UInt64 = 1, productID: String = TipJarService.productIDs[0],
        productType: Product.ProductType = .consumable, revocationDate: Date? = nil
    ) {
        self.id = id
        self.productID = productID
        self.productType = productType
        self.revocationDate = revocationDate
    }

    func finish() async {
        finishCalls += 1
        await onFinish()
    }
}

@MainActor
private final class TipTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}
