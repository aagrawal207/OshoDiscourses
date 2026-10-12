import Foundation
import StoreKit
import StoreKitTest
import Testing
@testable import OshoDiscourses

@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct AnnualSupportStoreKitTests {
    @Test func catalogHasThreeAnnualAmountsAndUnchangedOneTimeTips() async throws {
        let session = try session()
        defer { session.clearTransactions() }
        let support = AnnualSupportService()
        let loaded = try await Product.products(for: AnnualSupportService.productIDs)
        #expect(loaded.count == 3)
        await support.loadProducts { loaded }
        #expect(support.loadError == nil)
        #expect(support.statusError == nil)
        #expect(support.products.map(\.price) == [5, 10, 15])
        #expect(Set(support.products.compactMap { $0.subscription?.subscriptionGroupID }).count == 1)
        #expect(support.products.allSatisfy(AnnualSupportService.isAnnualSupport))

        let tips = TipJarService(defaults: UserDefaults(suiteName: "AnnualSupportStoreKitTests.catalog")!)
        await tips.loadProducts()
        #expect(tips.loadError == nil)
        #expect(tips.products.map(\.price) == [3, 5, 10, 25, 50])
        #expect(tips.products.allSatisfy { $0.type == .consumable })
        let ordered = TipJarView.orderedProducts(support.products + tips.products)
        #expect(ordered.map(\.price) == [3, 5, 5, 10, 10, 15, 25, 50])
        #expect(ordered.map(\.type) == [.consumable, .consumable, .autoRenewable, .consumable, .autoRenewable, .autoRenewable, .consumable, .consumable])
    }

    @Test func purchaseRenewalCancellationExpiryAndRelaunch() async throws {
        let session = try session()
        defer { session.clearTransactions() }
        let support = AnnualSupportService()
        await support.loadProducts()
        let product = try #require(support.products.first)
        #expect(support.canPurchase)
        await support.purchase(product)
        #expect(support.state == .thanked)
        #expect(support.currentProductID == product.id)
        support.dismissMessage()
        #expect(!support.canPurchase)

        try session.forceRenewalOfSubscription(productIdentifier: product.id)
        await support.refreshStatus()
        #expect(support.currentProductID == product.id)
        let transaction = try #require(session.allTransactions().max { $0.identifier < $1.identifier })
        try session.disableAutoRenewForTransaction(identifier: transaction.identifier)
        let cancellationDeadline = ContinuousClock.now + .seconds(10)
        var autoRenewDisabled = false
        repeat {
            let statuses = try await product.subscription?.status ?? []
            autoRenewDisabled = statuses.contains {
                if case .verified(let renewal) = $0.renewalInfo { return !renewal.willAutoRenew }
                return false
            }
            if !autoRenewDisabled { try await Task.sleep(for: .milliseconds(100)) }
        } while !autoRenewDisabled && ContinuousClock.now < cancellationDeadline
        #expect(autoRenewDisabled)
        await support.refreshStatus()
        #expect(support.currentProductID == product.id)

        let relaunched = AnnualSupportService()
        await relaunched.loadProducts()
        #expect(relaunched.currentProductID == product.id)
        #expect(!relaunched.canPurchase)

        try session.expireSubscription(productIdentifier: product.id)
        try await waitForSubscription(nil, in: relaunched)
        if relaunched.currentProductID != nil {
            for status in try await product.subscription?.status ?? [] {
                let value = status.transaction.unsafePayloadValue
                print("Expiry diagnostic: state=\(status.state), expires=\(String(describing: value.expirationDate)), now=\(Date()), autoRenew=\(status.renewalInfo.unsafePayloadValue.willAutoRenew)")
            }
        }
        #expect(relaunched.currentProductID == nil)
        #expect(relaunched.canPurchase)
    }

    @Test func refundClearsStatusAndRestoreUsesAppleState() async throws {
        let session = try session()
        defer { session.clearTransactions() }
        let support = AnnualSupportService()
        await support.loadProducts()
        let product = try #require(support.products.last)
        let transaction = try await session.buyProduct(identifier: product.id)
        await support.restore()
        #expect(support.currentProductID == product.id)
        #expect(support.restoreMessage?.contains("restored") == true)
        try session.refundTransaction(identifier: UInt(transaction.id))
        try await waitForSubscription(nil, in: support)
        #expect(support.currentProductID == nil)
        #expect(support.canPurchase)
    }

    @Test func askToBuyApprovalClearsPendingWithoutAnUnsolicitedAlert() async throws {
        let session = try session()
        defer { session.clearTransactions() }
        let support = AnnualSupportService(observeTransactions: true)
        await support.loadProducts()
        let product = try #require(support.products.first)
        session.askToBuyEnabled = true
        await support.purchase(product)
        #expect(support.state == .pending)
        let transaction = try #require(session.allTransactions().last)
        try session.approveAskToBuyTransaction(identifier: transaction.identifier)
        try await waitForSubscription(product.id, in: support)
        #expect(support.currentProductID == product.id)
        #expect(support.state == .idle)
    }

    private func session() throws -> SKTestSession {
        let url = try #require(Bundle(for: StoreKitBundle.self).url(forResource: "TipJar", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        return session
    }

    private func waitForSubscription(_ productID: String?, in support: AnnualSupportService) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        repeat {
            await support.refreshStatus()
            if support.currentProductID == productID && support.statusIsCurrent { return }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
    }
}

private final class StoreKitBundle: NSObject {}
