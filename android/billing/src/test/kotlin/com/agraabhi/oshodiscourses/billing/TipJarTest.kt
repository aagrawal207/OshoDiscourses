package com.agraabhi.oshodiscourses.billing

import com.agraabhi.oshodiscourses.billing.FakeBillingGateway.Companion.purchase
import com.agraabhi.oshodiscourses.billing.TipJar.Outcome
import com.agraabhi.oshodiscourses.billing.TipJar.Source
import com.agraabhi.oshodiscourses.core.domain.support.PurchaseState
import com.google.common.truth.Truth.assertThat
import java.io.File
import kotlin.test.assertFailsWith
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class TipJarTest {
    @get:Rule val folder = TemporaryFolder()

    private val small = "com.agraabhi.oshodiscourses.tip.small"
    private val medium = "com.agraabhi.oshodiscourses.tip.medium"
    private val gateway = FakeBillingGateway()

    private fun ledger() = JsonFileStore(File(folder.root, "tip_jar.json"), TipLedger.serializer(), TipLedger())

    private fun tipJar() = TipJar(gateway, TestVerifier, ledger())

    private suspend fun loadedTipJar() = tipJar().also { it.loadProducts() }

    private fun purchased(vararg purchases: StorePurchase): suspend (StoreProduct) -> FlowResult =
        { FlowResult.Purchased(purchases.toList()) }

    @Test
    fun onlyIntendedConsumablesAreEligible() {
        val ids = listOf(
            "com.agraabhi.oshodiscourses.tip.small",
            "com.agraabhi.oshodiscourses.tip.medium",
            "com.agraabhi.oshodiscourses.tip.large",
            "com.agraabhi.oshodiscourses.tip.grand",
            "com.agraabhi.oshodiscourses.tip.patron",
        )
        assertThat(SupportProducts.tipIDs).containsExactlyElementsIn(ids).inOrder()
        for (id in ids) {
            assertThat(SupportProducts.isTip(id, ProductKind.ONE_TIME)).isTrue()
            assertThat(SupportProducts.isTip(id, ProductKind.SUBSCRIPTION)).isFalse()
        }
        assertThat(SupportProducts.isTip("unrelated.product", ProductKind.ONE_TIME)).isFalse()
        assertThat(SupportProducts.isTip("oshodiscourses.support.annual5", ProductKind.ONE_TIME)).isFalse()
    }

    @Test
    fun productsAreSortedByPriceAndPartialCatalogsExplainThemselves() = runTest {
        gateway.products = { kind, ids -> FakeBillingGateway.catalog(kind, ids.reversed().drop(1)) }
        val tips = loadedTipJar()
        assertThat(tips.state.value.products.map { it.displayPrice }).containsExactly("$3.00", "$5.00", "$10.00", "$25.00").inOrder()
        assertThat(tips.state.value.loadError)
            .isEqualTo("Some tips aren't available right now. You can choose an available tip or try again.")

        gateway.products = FakeBillingGateway::catalog
        tips.loadProducts()
        assertThat(tips.state.value.products).hasSize(5)
        assertThat(tips.state.value.loadError).isNull()
    }

    @Test
    fun emptyCatalogCanBeRetried() = runTest {
        gateway.products = { _, _ -> emptyList() }
        val tips = tipJar()
        repeat(2) {
            tips.loadProducts()
            assertThat(tips.state.value.products).isEmpty()
            assertThat(tips.state.value.loadError)
                .isEqualTo("Tips aren't available in Google Play right now. Please try again later.")
            assertThat(tips.state.value.isLoading).isFalse()
            assertThat(tips.state.value.tipCount).isEqualTo(0)
        }
        assertThat(gateway.productQueries).isEqualTo(2)
    }

    @Test
    fun failedAndCancelledCatalogLoadsReleaseRetryGate() = runTest {
        val tips = tipJar()
        gateway.products = { _, _ -> throw BillingException(BillingError.NETWORK) }
        tips.loadProducts()
        assertThat(tips.state.value.loadError)
            .isEqualTo("Couldn't load tips from Google Play. Check your connection and try again.")
        assertThat(tips.state.value.products).isEmpty()
        assertThat(tips.state.value.isLoading).isFalse()

        gateway.products = { _, _ ->
            assertThat(tips.state.value.loadError).isNull()
            throw CancellationException("interrupted")
        }
        assertFailsWith<CancellationException> { tips.loadProducts() }
        assertThat(tips.state.value.loadError).isEqualTo("Loading was interrupted. Please try again.")
        assertThat(tips.state.value.isLoading).isFalse()

        var retried = false
        gateway.products = { _, _ ->
            retried = true
            emptyList()
        }
        tips.loadProducts()
        assertThat(retried).isTrue()
    }

    @Test
    fun productLoadingBlocksOverlappingLoadsAndPurchases() = runTest {
        val tips = loadedTipJar()
        val entered = Gate()
        val release = Gate()
        gateway.products = { kind, ids ->
            entered.open()
            release.await()
            FakeBillingGateway.catalog(kind, ids)
        }
        val loading = launch { tips.loadProducts() }
        entered.await()
        assertThat(tips.state.value.isLoading).isTrue()
        assertThat(tips.state.value.canPurchase).isFalse()

        tips.loadProducts()
        tips.purchase(small)
        assertThat(gateway.productQueries).isEqualTo(2)
        assertThat(gateway.launches).isEqualTo(0)
        release.open()
        loading.join()
        assertThat(tips.state.value.isLoading).isFalse()
    }

    @Test
    fun verifiedPurchasePersistsBeforeConsumeAndThanksAfterward() = runTest {
        val tips = loadedTipJar()
        val transaction = purchase(small)
        val entered = Gate()
        val release = Gate()
        gateway.onConsume = {
            entered.open()
            release.await()
        }
        gateway.launch = purchased(transaction)
        val buying = launch { tips.purchase(small) }
        entered.await()

        assertThat(tips.state.value.tipCount).isEqualTo(1)
        assertThat(tipJar().state.value.tipCount).isEqualTo(1)
        assertThat(tips.state.value.state).isEqualTo(PurchaseState.Purchasing(small))
        assertThat(tips.state.value.isPurchasing).isTrue()
        assertThat(tips.state.value.canPurchase).isFalse()
        tips.dismissMessage()
        assertThat(tips.state.value.state).isEqualTo(PurchaseState.Purchasing(small))

        release.open()
        buying.join()
        assertThat(gateway.consumeCount(transaction.purchaseToken)).isEqualTo(1)
        assertThat(tips.state.value.state).isEqualTo(PurchaseState.Thanked)
        assertThat(tips.state.value.isPurchasing).isFalse()

        tips.purchase(small)
        assertThat(gateway.launches).isEqualTo(1)
        assertThat(tips.state.value.tipCount).isEqualTo(1)
        tips.dismissMessage()
        assertThat(tips.state.value.canPurchase).isTrue()
    }

    @Test
    fun duplicateDeliveriesDoNotCountOrThankTwice() = runTest {
        for (source in listOf(Source.UPDATE, Source.RECOVERY)) {
            folder.root.listFiles()?.forEach { it.delete() }
            gateway.consumed.clear()
            val tips = tipJar()
            val transaction = purchase(small)
            assertThat(tips.handle(transaction, source)).isEqualTo(Outcome.COMPLETED)
            assertThat(tips.state.value.state).isEqualTo(PurchaseState.Thanked)
            tips.dismissMessage()

            assertThat(tips.handle(transaction, source)).isEqualTo(Outcome.DUPLICATE)
            assertThat(tips.state.value.state).isEqualTo(PurchaseState.Idle)
            assertThat(tips.state.value.tipCount).isEqualTo(1)
            assertThat(gateway.consumeCount(transaction.purchaseToken)).isEqualTo(2)

            val relaunched = tipJar()
            assertThat(relaunched.handle(transaction, Source.RECOVERY)).isEqualTo(Outcome.DUPLICATE)
            assertThat(relaunched.state.value.tipCount).isEqualTo(1)
            assertThat(relaunched.state.value.state).isEqualTo(PurchaseState.Idle)
            assertThat(gateway.consumeCount(transaction.purchaseToken)).isEqualTo(3)
        }
    }

    @Test
    fun separateTipsForTheSameProductAreCountedSeparately() = runTest {
        val tips = loadedTipJar()
        val first = purchase(small, order = "GPA.1")
        val second = purchase(small, order = "GPA.2")
        gateway.launch = purchased(first)
        tips.purchase(small)
        tips.dismissMessage()
        gateway.launch = purchased(second)
        tips.purchase(small)
        assertThat(tips.state.value.tipCount).isEqualTo(2)
        assertThat(gateway.consumeCount(first.purchaseToken)).isEqualTo(1)
        assertThat(gateway.consumeCount(second.purchaseToken)).isEqualTo(1)
        assertThat(tips.state.value.state).isEqualTo(PurchaseState.Thanked)
    }

    @Test
    fun purchaseWithoutOrderIDIsKeyedByToken() = runTest {
        val tips = tipJar()
        val transaction = purchase(small, order = null, token = "license-test-token")
        assertThat(tips.handle(transaction, Source.UPDATE)).isEqualTo(Outcome.COMPLETED)
        assertThat(tips.handle(transaction, Source.RECOVERY)).isEqualTo(Outcome.DUPLICATE)
        assertThat(tips.state.value.tipCount).isEqualTo(1)
    }

    @Test
    fun pendingPurchaseWaitsForVerifiedApproval() = runTest {
        val tips = loadedTipJar()
        val pending = purchase(small, order = null, token = "pending-token", status = PurchaseStatus.PENDING)
        gateway.launch = purchased(pending)
        tips.purchase(small)
        assertThat(tips.state.value.state).isEqualTo(PurchaseState.Pending)
        assertThat(tips.state.value.tipCount).isEqualTo(0)
        assertThat(tips.state.value.isPurchasing).isFalse()
        assertThat(gateway.consumed).isEmpty()
        tips.dismissMessage()

        assertThat(tips.handle(pending, Source.RECOVERY)).isEqualTo(Outcome.PENDING)
        assertThat(tips.state.value.state).isEqualTo(PurchaseState.Idle)

        val approval = pending.copy(orderId = "GPA.7", status = PurchaseStatus.PURCHASED)
        tips.handle(approval, Source.UPDATE)
        assertThat(tips.state.value.state).isEqualTo(PurchaseState.Thanked)
        assertThat(tips.state.value.tipCount).isEqualTo(1)
        assertThat(gateway.consumeCount("pending-token")).isEqualTo(1)
    }

    @Test
    fun userCancellationDoesNotConfirmOrFailPurchase() = runTest {
        val tips = loadedTipJar()
        gateway.launch = { FlowResult.Cancelled }
        tips.purchase(small)
        assertThat(tips.state.value.state).isEqualTo(PurchaseState.Idle)
        assertThat(tips.state.value.canPurchase).isTrue()
        assertThat(tips.state.value.tipCount).isEqualTo(0)

        gateway.launch = { throw CancellationException("interrupted") }
        assertFailsWith<CancellationException> { tips.purchase(small) }
        assertThat(tips.state.value.state).isEqualTo(PurchaseState.Idle)
        assertThat(tips.state.value.canPurchase).isTrue()
        assertThat(tips.state.value.tipCount).isEqualTo(0)
    }

    @Test
    fun unavailableAndRestrictedPurchasesDoNotCount() = runTest {
        val tips = loadedTipJar()
        val expected = mapOf(
            BillingError.ITEM_UNAVAILABLE to "This tip is currently unavailable in Google Play. Please try again later.",
            BillingError.BILLING_UNAVAILABLE to "In-app purchases aren't allowed on this device.",
            BillingError.NO_ACTIVITY to "Google Play couldn't open the purchase. Please try again.",
        )
        for ((error, message) in expected) {
            gateway.launch = { FlowResult.Failed(error) }
            tips.purchase(small)
            assertThat(tips.state.value.state).isEqualTo(PurchaseState.Failed(message))
            assertThat(tips.state.value.tipCount).isEqualTo(0)
            assertThat(tips.state.value.isPurchasing).isFalse()
            tips.dismissMessage()
            assertThat(tips.state.value.canPurchase).isTrue()
        }
    }

    @Test
    fun failedPurchaseCanBeRetriedWithoutExposingRawError() = runTest {
        val tips = loadedTipJar()
        gateway.launch = { throw IllegalStateException("private-purchase-payload") }
        tips.purchase(small)
        val failed = tips.state.value.state as PurchaseState.Failed
        assertThat(failed.message).doesNotContain("private-purchase-payload")
        assertThat(failed.message)
            .isEqualTo("We couldn't confirm your tip. Check your Google Play purchase history before trying again.")
        assertThat(tips.state.value.tipCount).isEqualTo(0)
        assertThat(tips.state.value.isPurchasing).isFalse()
        tips.dismissMessage()

        gateway.launch = { FlowResult.Failed(BillingError.NETWORK) }
        tips.purchase(small)
        assertThat(tips.state.value.state).isInstanceOf(PurchaseState.Failed::class.java)
        tips.dismissMessage()
        gateway.launch = { FlowResult.Cancelled }
        tips.purchase(small)
        assertThat(tips.state.value.state).isEqualTo(PurchaseState.Idle)
    }

    @Test
    fun unverifiedPurchaseIsNotCountedOrConsumedAndCanRecover() = runTest {
        val tips = loadedTipJar()
        val unverified = purchase(small, signature = "forged")
        gateway.launch = purchased(unverified)
        tips.purchase(small)
        assertThat(tips.state.value.state).isEqualTo(
            PurchaseState.Failed("The Google Play purchase could not be verified. Check your purchase history before trying again."),
        )
        assertThat(tips.state.value.tipCount).isEqualTo(0)
        assertThat(gateway.consumed).isEmpty()
        tips.dismissMessage()

        tips.handle(unverified.copy(signature = "valid"), Source.RECOVERY)
        assertThat(tips.state.value.tipCount).isEqualTo(1)
        assertThat(tips.state.value.state).isEqualTo(PurchaseState.Thanked)
        assertThat(gateway.consumeCount(unverified.purchaseToken)).isEqualTo(1)
    }

    @Test
    fun unverifiedBackgroundDeliveryIsNotConsumed() = runTest {
        for (source in listOf(Source.UPDATE, Source.RECOVERY)) {
            val tips = tipJar()
            val transaction = purchase(small, signature = "forged")
            assertThat(tips.handle(transaction, source)).isEqualTo(Outcome.UNVERIFIED)
            assertThat(gateway.consumed).isEmpty()
            assertThat(tips.state.value.tipCount).isEqualTo(0)
            assertThat(tips.state.value.state).isInstanceOf(PurchaseState.Failed::class.java)
        }
    }

    @Test
    fun unrelatedAndSubscriptionPurchasesAreNotConsumed() = runTest {
        val tips = loadedTipJar()
        for (transaction in listOf(purchase("unrelated.product"), purchase("oshodiscourses.support.annual5"))) {
            assertThat(tips.handle(transaction, Source.UPDATE)).isEqualTo(Outcome.UNSUPPORTED)
            assertThat(gateway.consumed).isEmpty()
            assertThat(tips.state.value.tipCount).isEqualTo(0)
            assertThat(tips.state.value.state).isEqualTo(PurchaseState.Idle)

            gateway.launch = purchased(transaction)
            tips.purchase(small)
            assertThat(tips.state.value.state).isInstanceOf(PurchaseState.Failed::class.java)
            assertThat(gateway.consumed).isEmpty()
            assertThat(tips.state.value.tipCount).isEqualTo(0)
            tips.dismissMessage()
        }
        tips.handle(purchase("unrelated.product", signature = "forged"), Source.UPDATE)
        assertThat(tips.state.value.state).isEqualTo(PurchaseState.Idle)
        assertThat(gateway.consumed).isEmpty()
    }

    @Test
    fun unsupportedProductsNeverStartPurchase() = runTest {
        gateway.products = { _, _ ->
            listOf(FakeBillingGateway.tip(small, ProductKind.SUBSCRIPTION), FakeBillingGateway.tip("unrelated.product"))
        }
        val tips = loadedTipJar()
        assertThat(tips.state.value.products).isEmpty()
        for (id in listOf(small, "unrelated.product")) {
            tips.purchase(id)
            assertThat(gateway.launches).isEqualTo(0)
            assertThat(tips.state.value.tipCount).isEqualTo(0)
            assertThat(tips.state.value.state)
                .isEqualTo(PurchaseState.Failed("This tip is not available. Please reload the tip jar."))
            tips.dismissMessage()
        }
    }

    @Test
    fun anotherProductsPurchaseCannotConfirmPurchase() = runTest {
        val tips = loadedTipJar()
        val transaction = purchase(medium)
        gateway.launch = purchased(transaction)
        tips.purchase(small)
        assertThat(tips.state.value.state).isInstanceOf(PurchaseState.Failed::class.java)
        assertThat(tips.state.value.tipCount).isEqualTo(0)
        assertThat(gateway.consumed).isEmpty()
        tips.dismissMessage()

        tips.handle(transaction, Source.UPDATE)
        assertThat(tips.state.value.tipCount).isEqualTo(1)
        assertThat(gateway.consumeCount(transaction.purchaseToken)).isEqualTo(1)
    }

    @Test
    fun alreadyOwnedRecoversTheUnconsumedTip() = runTest {
        val tips = loadedTipJar()
        val earlier = purchase(small, order = "GPA.earlier")
        gateway.launch = { FlowResult.Failed(BillingError.ALREADY_OWNED) }
        gateway.purchases = { listOf(earlier) }
        tips.purchase(small)
        assertThat(tips.state.value.state).isEqualTo(PurchaseState.Thanked)
        assertThat(tips.state.value.tipCount).isEqualTo(1)
        assertThat(gateway.consumeCount(earlier.purchaseToken)).isEqualTo(1)
        tips.dismissMessage()

        // Recorded but never consumed: consume it again so the next tip can go through, without a recount.
        tips.purchase(small)
        assertThat(tips.state.value.state).isInstanceOf(PurchaseState.Failed::class.java)
        assertThat(tips.state.value.tipCount).isEqualTo(1)
        assertThat(gateway.consumeCount(earlier.purchaseToken)).isEqualTo(2)
    }

    @Test
    fun failedConsumeKeepsTheCreditAndRecoveryRetriesWithoutRecount() = runTest {
        val tips = loadedTipJar()
        val transaction = purchase(small)
        gateway.onConsume = { throw BillingException(BillingError.NETWORK) }
        gateway.launch = purchased(transaction)
        tips.purchase(small)
        assertThat(tips.state.value.state).isEqualTo(PurchaseState.Thanked)
        assertThat(tips.state.value.tipCount).isEqualTo(1)

        gateway.onConsume = {}
        gateway.purchases = { listOf(transaction) }
        assertThat(tips.recover()).containsExactly(Outcome.DUPLICATE)
        assertThat(tips.state.value.tipCount).isEqualTo(1)
        assertThat(gateway.consumeCount(transaction.purchaseToken)).isEqualTo(2)
    }

    @Test
    fun purchaseAndUpdateShareConsumeAndCreditOnlyOnce() = runTest {
        val tips = loadedTipJar()
        val transaction = purchase(small)
        val consumeEntered = Gate()
        val consumeRelease = Gate()
        gateway.onConsume = {
            consumeEntered.open()
            consumeRelease.await()
        }
        var updateOutcome: Outcome? = null
        val update = launch { updateOutcome = tips.handle(transaction, Source.UPDATE) }
        consumeEntered.await()
        tips.dismissMessage()

        val purchaseEntered = Gate()
        gateway.launch = {
            purchaseEntered.open()
            FlowResult.Purchased(listOf(transaction))
        }
        val buying = launch { tips.purchase(small) }
        purchaseEntered.await()
        assertThat(gateway.consumeCount(transaction.purchaseToken)).isEqualTo(1)
        assertThat(tips.state.value.tipCount).isEqualTo(1)
        assertThat(tips.state.value.isPurchasing).isTrue()

        consumeRelease.open()
        buying.join()
        update.join()
        assertThat(updateOutcome).isEqualTo(Outcome.COMPLETED)
        assertThat(gateway.consumeCount(transaction.purchaseToken)).isEqualTo(1)
        assertThat(tips.state.value.tipCount).isEqualTo(1)
        assertThat(tips.state.value.state).isEqualTo(PurchaseState.Thanked)
    }

    @Test
    fun backgroundApprovalDoesNotUnlockOrReplaceAnotherPurchase() = runTest {
        for (cancelled in listOf(false, true)) {
            folder.root.listFiles()?.forEach { it.delete() }
            gateway.consumed.clear()
            val tips = loadedTipJar()
            val queriesBefore = gateway.productQueries
            val launchesBefore = gateway.launches
            val entered = Gate()
            val release = Gate()
            gateway.launch = {
                entered.open()
                release.await()
                if (cancelled) {
                    FlowResult.Cancelled
                } else {
                    FlowResult.Purchased(listOf(purchase(medium, order = null, token = "pending", status = PurchaseStatus.PENDING)))
                }
            }
            val buying = launch { tips.purchase(medium) }
            entered.await()

            val approval = purchase(small, order = "GPA.approval")
            tips.handle(approval, Source.UPDATE)
            assertThat(tips.state.value.tipCount).isEqualTo(1)
            assertThat(gateway.consumeCount(approval.purchaseToken)).isEqualTo(1)
            assertThat(tips.state.value.state).isEqualTo(PurchaseState.Purchasing(medium))

            val unverified = purchase(medium, order = "GPA.2", signature = "forged")
            tips.handle(unverified, Source.UPDATE)
            assertThat(gateway.consumeCount(unverified.purchaseToken)).isEqualTo(0)
            assertThat(tips.state.value.state).isEqualTo(PurchaseState.Purchasing(medium))
            tips.dismissMessage()
            assertThat(tips.state.value.canPurchase).isFalse()

            tips.purchase(small)
            tips.loadProducts()
            assertThat(gateway.launches).isEqualTo(launchesBefore + 1)
            assertThat(gateway.productQueries).isEqualTo(queriesBefore)

            release.open()
            buying.join()
            assertThat(tips.state.value.state).isEqualTo(if (cancelled) PurchaseState.Idle else PurchaseState.Pending)
            assertThat(tips.state.value.isPurchasing).isFalse()
        }
    }

    @Test
    fun corruptLedgerStartsEmptyInsteadOfCrashing() = runTest {
        File(folder.root, "tip_jar.json").writeText("{not json")
        val tips = tipJar()
        assertThat(tips.state.value.tipCount).isEqualTo(0)
        tips.handle(purchase(small), Source.UPDATE)
        assertThat(tipJar().state.value.tipCount).isEqualTo(1)
    }
}
