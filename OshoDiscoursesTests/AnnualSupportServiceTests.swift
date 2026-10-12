import Foundation
import StoreKit
import Testing
@testable import OshoDiscourses

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct AnnualSupportServiceTests {
    private let productID = AnnualSupportService.productIDs[0]

    @Test func onlyAnnualSupportIDsAcceptSubscriptionTransactions() {
        for id in AnnualSupportService.productIDs {
            #expect(AnnualSupportService.isAnnualSupport(productID: id, type: .autoRenewable))
            for type in [Product.ProductType.consumable, .nonConsumable, .nonRenewable] {
                #expect(!AnnualSupportService.isAnnualSupport(productID: id, type: type))
            }
            #expect(!TipJarService.isTip(productID: id, type: .autoRenewable))
        }
        #expect(!AnnualSupportService.isAnnualSupport(productID: TipJarService.productIDs[0], type: .autoRenewable))
    }

    @Test(arguments: [Product.SubscriptionInfo.RenewalState.subscribed, .inGracePeriod, .inBillingRetryPeriod])
    func existingSubscriptionBlocksAllAnnualPurchases(state: Product.SubscriptionInfo.RenewalState) async {
        let service = AnnualSupportService(loadStatuses: { _ in [.init(productID: productID, state: state)] })
        #expect(!service.canPurchase)
        await service.refreshStatus()
        #expect(service.currentProductID == productID)
        for id in AnnualSupportService.productIDs {
            await service.purchase(productID: id, type: .autoRenewable) {
                Issue.record("Existing support must be managed, not purchased twice")
                return .thanked
            }
        }
        #expect(service.state == .idle)
    }

    @Test(arguments: [Product.SubscriptionInfo.RenewalState.expired, .revoked])
    func endedSubscriptionsPermitNewSupport(state: Product.SubscriptionInfo.RenewalState) async {
        let service = AnnualSupportService(loadStatuses: { _ in [.init(productID: productID, state: state)] })
        await service.refreshStatus()
        #expect(service.currentProductID == nil)
        #expect(service.canPurchase)
    }

    @Test func futureProductInSameGroupAlsoBlocksDuplicateSubscription() async {
        let service = AnnualSupportService(loadStatuses: { _ in [.init(productID: "future.annual", state: .subscribed)] })
        await service.refreshStatus()
        #expect(service.currentProductID == "future.annual")
        #expect(!service.canPurchase)
    }

    @Test func statusFailureDisablesPurchaseUntilVerifiedRetry() async {
        let stub = AnnualStatusStub()
        stub.error = URLError(.notConnectedToInternet)
        let service = AnnualSupportService(loadStatuses: { _ in try stub.load() })
        await service.refreshStatus()
        #expect(service.statusError != nil)
        #expect(!service.statusIsCurrent)
        #expect(!service.canPurchase)
        stub.error = nil
        await service.refreshStatus()
        #expect(service.statusError == nil)
        #expect(service.canPurchase)
    }

    @Test func missingAndFailedProductLoadsRemainRetryable() async {
        let service = AnnualSupportService(loadStatuses: { _ in [] })
        await service.loadProducts { throw URLError(.notConnectedToInternet) }
        #expect(service.products.isEmpty)
        #expect(service.loadError != nil)
        #expect(!service.isLoading)
        #expect(!service.statusIsCurrent)
        await service.loadProducts { [] }
        #expect(service.products.isEmpty)
        #expect(service.loadError != nil)
        #expect(!service.isBusy)
    }

    @Test func purchasesHandlePendingCancellationAndFailureWithoutOverlapping() async {
        let service = AnnualSupportService(loadStatuses: { _ in [] })
        await service.refreshStatus()
        await service.purchase(productID: productID, type: .autoRenewable) {
            #expect(service.isPurchasing)
            #expect(!service.canPurchase)
            await service.purchase(productID: productID, type: .autoRenewable) {
                Issue.record("A second purchase started")
                return .thanked
            }
            return .pending
        }
        #expect(service.state == .pending)
        service.dismissMessage()
        #expect(!service.canPurchase)
        service.clearDeclinedRequest()
        await service.purchase(productID: productID, type: .autoRenewable) { throw StoreKitError.userCancelled }
        #expect(service.state == .idle)
        await service.purchase(productID: productID, type: .autoRenewable) { throw CancellationError() }
        #expect(service.state == .idle)
        await service.purchase(productID: productID, type: .autoRenewable) { throw URLError(.timedOut) }
        guard case .failed = service.state else {
            Issue.record("A failed purchase must not be thanked")
            return
        }
        #expect(!service.isPurchasing)
        service.dismissMessage()
        #expect(service.canPurchase)
    }

    @Test func invalidProductsNeverStartPurchasing() async {
        let service = AnnualSupportService(loadStatuses: { _ in [] })
        await service.refreshStatus()
        for (id, type) in [(productID, Product.ProductType.consumable), ("unknown", .autoRenewable)] {
            await service.purchase(productID: id, type: type) {
                Issue.record("An invalid product was purchased")
                return .thanked
            }
        }
        #expect(service.state == .idle)
    }

    @Test func verifiedPurchaseFinishesAndRefreshesCurrentSupport() async {
        let transaction = AnnualTestTransaction(productID: productID)
        let service = AnnualSupportService(loadStatuses: { _ in [.init(productID: productID, state: .subscribed)] })
        let state = await service.purchaseState(for: .verified(transaction), productID: productID)
        #expect(state == .thanked)
        #expect(transaction.finishCalls == 1)
        #expect(service.currentProductID == productID)
        #expect(!service.canPurchase)
    }

    @Test func verificationWrongProductAndRevocationNeverReportSuccess() async {
        let service = AnnualSupportService(loadStatuses: { _ in [] })
        let unverified = AnnualTestTransaction(productID: productID)
        #expect(!(await service.finish(.unverified(unverified, .invalidSignature))))
        #expect(unverified.finishCalls == 0)
        let wrong = AnnualTestTransaction(productID: AnnualSupportService.productIDs[1])
        #expect(!(await service.finish(.verified(wrong), expectedProductID: productID)))
        #expect(wrong.finishCalls == 0)
        let tip = AnnualTestTransaction(productID: TipJarService.productIDs[0])
        #expect(!(await service.finish(.verified(tip))))
        #expect(tip.finishCalls == 0)
        let revoked = AnnualTestTransaction(productID: productID, revocationDate: Date())
        guard case .failed = await service.purchaseState(for: .verified(revoked), productID: productID) else {
            Issue.record("Revoked support must not report success")
            return
        }
        #expect(revoked.finishCalls == 1)
    }

    @Test func verifiedTransactionWithoutCurrentPlanDoesNotReportSuccess() async {
        let transaction = AnnualTestTransaction(productID: productID)
        let service = AnnualSupportService(loadStatuses: { _ in [] })
        guard case .failed = await service.purchaseState(for: .verified(transaction), productID: productID) else {
            Issue.record("A stale transaction must not report current support")
            return
        }
        #expect(transaction.finishCalls == 1)
        #expect(service.currentProductID == nil)
    }

    @Test func renewalAndRefundUpdatesRefreshStatusWithoutThankYouPopups() async {
        let stub = AnnualStatusStub()
        stub.statuses = [.init(productID: productID, state: .subscribed)]
        let service = AnnualSupportService(loadStatuses: { _ in try stub.load() })
        let renewal = AnnualTestTransaction(productID: productID)
        await service.handleUpdate(.verified(renewal))
        #expect(service.currentProductID == productID)
        #expect(service.state == .idle)
        stub.statuses = [.init(productID: productID, state: .revoked)]
        let refund = AnnualTestTransaction(productID: productID, revocationDate: Date())
        await service.handleUpdate(.verified(refund))
        #expect(service.currentProductID == nil)
        #expect(service.state == .idle)
        #expect(service.canPurchase)
        #expect(renewal.finishCalls == 1)
        #expect(refund.finishCalls == 1)
    }

    @Test func delayedApprovalClearsPendingWithoutPresentingAnAlert() async {
        let stub = AnnualStatusStub()
        let service = AnnualSupportService(loadStatuses: { _ in try stub.load() })
        await service.refreshStatus()
        await service.purchase(productID: productID, type: .autoRenewable) { .pending }
        #expect(service.state == .pending)
        stub.statuses = [.init(productID: productID, state: .subscribed)]
        await service.handleUpdate(.verified(AnnualTestTransaction(productID: productID)))
        #expect(service.currentProductID == productID)
        #expect(service.state == .idle)
        #expect(service.pendingProductID == nil)
    }

    @Test func dismissingPendingDoesNotEnableOtherAmountsAfterRelaunch() async {
        let suite = "AnnualSupportServiceTests.pending.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = AnnualSupportService(defaults: defaults, loadStatuses: { _ in [] })
        await service.refreshStatus()
        await service.purchase(productID: productID, type: .autoRenewable) { .pending }
        service.dismissMessage()
        #expect(service.state == .idle)
        #expect(service.pendingProductID == productID)
        #expect(!service.canPurchase)
        let relaunched = AnnualSupportService(defaults: defaults, loadStatuses: { _ in [] })
        await relaunched.refreshStatus()
        #expect(relaunched.pendingProductID == productID)
        #expect(!relaunched.canPurchase)
        await relaunched.purchase(productID: AnnualSupportService.productIDs[1], type: .autoRenewable) {
            Issue.record("A pending request allowed another annual amount")
            return .thanked
        }
        relaunched.clearDeclinedRequest()
        #expect(relaunched.canPurchase)
    }

    @Test func restoreReportsFoundMissingCancelledAndFailedStates() async {
        let stub = AnnualStatusStub()
        stub.statuses = [.init(productID: productID, state: .subscribed)]
        let service = AnnualSupportService(loadStatuses: { _ in try stub.load() })
        await service.restore(using: {})
        #expect(service.currentProductID == productID)
        #expect(service.restoreMessage?.contains("restored") == true)
        stub.statuses = []
        await service.restore(using: {})
        #expect(service.currentProductID == nil)
        #expect(service.restoreMessage?.contains("No current") == true)
        await service.restore { throw StoreKitError.userCancelled }
        #expect(service.state == .idle)
        #expect(service.restoreMessage == nil)
        await service.restore { throw URLError(.notConnectedToInternet) }
        guard case .failed = service.state else {
            Issue.record("Restore failure was not reported")
            return
        }
        #expect(!service.isRestoring)
    }

    @Test func overlappingStatusRequestsWaitForTheFreshSnapshot() async {
        let entered = TipTestGate()
        let release = TipTestGate()
        let secondEntered = TipTestGate()
        let stub = AnnualStatusStub()
        stub.statuses = [.init(productID: productID, state: .subscribed)]
        let service = AnnualSupportService(loadStatuses: { _ in
            stub.calls += 1
            if stub.calls == 1 {
                entered.open()
                await release.wait()
                return []
            }
            return try stub.load()
        })
        let first = Task { await service.refreshStatus() }
        await entered.wait()
        let second = Task {
            secondEntered.open()
            await service.refreshStatus()
            #expect(service.currentProductID == productID)
        }
        await secondEntered.wait()
        #expect(service.isRefreshingStatus)
        release.open()
        await first.value
        await second.value
        #expect(stub.calls == 2)
        #expect(!service.isRefreshingStatus)
    }
}

@MainActor
private final class AnnualStatusStub {
    var statuses: [AnnualSupportService.Status] = []
    var error: Error?
    var calls = 0

    func load() throws -> [AnnualSupportService.Status] {
        if let error { throw error }
        return statuses
    }
}

@MainActor
private final class AnnualTestTransaction: TipJarTransaction {
    let id: UInt64 = 1
    let productID: String
    let productType: Product.ProductType = .autoRenewable
    let revocationDate: Date?
    var finishCalls = 0

    init(productID: String, revocationDate: Date? = nil) {
        self.productID = productID
        self.revocationDate = revocationDate
    }

    func finish() async { finishCalls += 1 }
}
