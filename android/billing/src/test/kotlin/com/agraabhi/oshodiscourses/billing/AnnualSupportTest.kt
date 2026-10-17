package com.agraabhi.oshodiscourses.billing

import com.agraabhi.oshodiscourses.billing.FakeBillingGateway.Companion.purchase
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

class AnnualSupportTest {
    @get:Rule val folder = TemporaryFolder()

    private val productID = "com.agraabhi.oshodiscourses.support.annual5"
    private val playID = "oshodiscourses.support.annual5"
    private val gateway = FakeBillingGateway()

    private fun annual() = AnnualSupport(
        gateway,
        TestVerifier,
        JsonFileStore(File(folder.root, "annual_support.json"), AnnualRecord.serializer(), AnnualRecord()),
    )

    private suspend fun loadedAnnual() = annual().also { it.loadProducts() }

    private fun subscribed(id: String = playID, order: String = "GPA.sub", suspended: Boolean = false) =
        purchase(id, order = order, acknowledged = true, suspended = suspended)

    @Test
    fun onlyAnnualSupportIDsAcceptSubscriptions() {
        assertThat(SupportProducts.annualPlayIDs).containsExactly(
            "com.agraabhi.oshodiscourses.support.annual5", "oshodiscourses.support.annual5",
            "com.agraabhi.oshodiscourses.support.annual10", "oshodiscourses.support.annual10",
            "com.agraabhi.oshodiscourses.support.annual15", "oshodiscourses.support.annual15",
        ).inOrder()
        for (id in SupportProducts.annualPlayIDs.values) {
            assertThat(SupportProducts.isAnnualSupport(FakeBillingGateway.annual(id))).isTrue()
            assertThat(SupportProducts.isAnnualSupport(FakeBillingGateway.annual(id).copy(kind = ProductKind.ONE_TIME))).isFalse()
            assertThat(SupportProducts.isAnnualSupport(FakeBillingGateway.annual(id, period = "P1M"))).isFalse()
            assertThat(SupportProducts.isAnnualSupport(FakeBillingGateway.annual(id, period = null))).isFalse()
            assertThat(SupportProducts.isTip(id)).isFalse()
        }
        assertThat(SupportProducts.isAnnualSupport(FakeBillingGateway.annual("com.agraabhi.oshodiscourses.tip.small"))).isFalse()
    }

    @Test
    fun productsLoadInPriceOrderUnderContractIDs() = runTest {
        gateway.products = { kind, ids -> FakeBillingGateway.catalog(kind, ids.reversed()) }
        val service = loadedAnnual()
        assertThat(service.state.value.products.map { it.id }).containsExactly(
            "com.agraabhi.oshodiscourses.support.annual5",
            "com.agraabhi.oshodiscourses.support.annual10",
            "com.agraabhi.oshodiscourses.support.annual15",
        ).inOrder()
        assertThat(service.state.value.products.map { it.displayPrice }).containsExactly("$5.00", "$10.00", "$15.00").inOrder()
        assertThat(service.state.value.loadError).isNull()
        assertThat(service.state.value.statusIsCurrent).isTrue()
        assertThat(service.state.value.canPurchase).isTrue()
    }

    @Test
    fun existingSubscriptionBlocksAllAnnualPurchases() = runTest {
        for (suspended in listOf(false, true)) {
            gateway.purchases = { listOf(subscribed(suspended = suspended)) }
            val service = annual()
            assertThat(service.state.value.canPurchase).isFalse()
            service.loadProducts()
            assertThat(service.state.value.currentProductID).isEqualTo(productID)
            for (id in SupportProducts.annualPlayIDs.keys) service.purchase(id)
            assertThat(gateway.launches).isEqualTo(0)
            assertThat(service.state.value.state).isEqualTo(PurchaseState.Idle)
        }
    }

    @Test
    fun endedSubscriptionsPermitNewSupport() = runTest {
        // Play stops listing a subscription once it expires or is revoked.
        gateway.purchases = { emptyList() }
        val service = annual()
        service.refreshStatus()
        assertThat(service.state.value.currentProductID).isNull()
        assertThat(service.state.value.canPurchase).isTrue()
    }

    @Test
    fun futureSubscriptionInTheAppAlsoBlocksDuplicateSubscription() = runTest {
        gateway.purchases = { listOf(subscribed(id = "oshodiscourses.support.future")) }
        val service = annual()
        service.refreshStatus()
        assertThat(service.state.value.currentProductID).isEqualTo("oshodiscourses.support.future")
        assertThat(service.state.value.canPurchase).isFalse()
    }

    @Test
    fun statusFailureDisablesPurchaseUntilVerifiedRetry() = runTest {
        var failure: Exception? = BillingException(BillingError.NETWORK)
        gateway.purchases = { failure?.let { throw it } ?: emptyList() }
        val service = annual()
        service.refreshStatus()
        assertThat(service.state.value.statusError)
            .isEqualTo("Couldn't check your existing yearly support. Try again before starting a subscription.")
        assertThat(service.state.value.statusIsCurrent).isFalse()
        assertThat(service.state.value.canPurchase).isFalse()
        failure = null
        service.refreshStatus()
        assertThat(service.state.value.statusError).isNull()
        assertThat(service.state.value.canPurchase).isTrue()
    }

    @Test
    fun unverifiedSubscriptionIsAStatusError() = runTest {
        gateway.purchases = { listOf(subscribed().copy(signature = "forged")) }
        val service = annual()
        service.refreshStatus()
        assertThat(service.state.value.statusError).isNotNull()
        assertThat(service.state.value.statusIsCurrent).isFalse()
        assertThat(service.state.value.canPurchase).isFalse()
    }

    @Test
    fun missingAndFailedProductLoadsRemainRetryable() = runTest {
        val service = annual()
        gateway.products = { _, _ -> throw BillingException(BillingError.NETWORK) }
        service.loadProducts()
        assertThat(service.state.value.products).isEmpty()
        assertThat(service.state.value.loadError)
            .isEqualTo("Couldn't load yearly support from Google Play. Check your connection and try again.")
        assertThat(service.state.value.isLoading).isFalse()
        assertThat(service.state.value.statusIsCurrent).isFalse()

        gateway.products = { _, _ -> emptyList() }
        service.loadProducts()
        assertThat(service.state.value.products).isEmpty()
        assertThat(service.state.value.loadError)
            .isEqualTo("Some yearly support options aren't available right now. Please try again later.")
        assertThat(service.state.value.isBusy).isFalse()
    }

    @Test
    fun purchasesHandlePendingCancellationAndFailureWithoutOverlapping() = runTest {
        val service = loadedAnnual()
        gateway.launch = {
            assertThat(service.state.value.isPurchasing).isTrue()
            assertThat(service.state.value.canPurchase).isFalse()
            service.purchase(productID)
            FlowResult.Purchased(listOf(purchase(playID, order = null, token = "pending", status = PurchaseStatus.PENDING)))
        }
        service.purchase(productID)
        assertThat(gateway.launches).isEqualTo(1)
        assertThat(service.state.value.state).isEqualTo(PurchaseState.Pending)
        service.dismissMessage()
        assertThat(service.state.value.canPurchase).isFalse()
        service.clearDeclinedRequest()

        gateway.launch = { FlowResult.Cancelled }
        service.purchase(productID)
        assertThat(service.state.value.state).isEqualTo(PurchaseState.Idle)

        gateway.launch = { throw CancellationException("interrupted") }
        assertFailsWith<CancellationException> { service.purchase(productID) }
        assertThat(service.state.value.state).isEqualTo(PurchaseState.Idle)

        gateway.launch = { FlowResult.Failed(BillingError.NETWORK) }
        service.purchase(productID)
        assertThat(service.state.value.state).isEqualTo(
            PurchaseState.Failed("Couldn't confirm your subscription. Check your Google Play subscriptions before trying again."),
        )
        assertThat(service.state.value.isPurchasing).isFalse()
        service.dismissMessage()
        assertThat(service.state.value.canPurchase).isTrue()
    }

    @Test
    fun invalidProductsNeverStartPurchasing() = runTest {
        gateway.products = { _, _ -> listOf(FakeBillingGateway.annual(playID, period = "P1M")) }
        val service = loadedAnnual()
        for (id in listOf(productID, "unknown")) service.purchase(id)
        assertThat(gateway.launches).isEqualTo(0)
        assertThat(service.state.value.state).isEqualTo(PurchaseState.Idle)
    }

    @Test
    fun verifiedPurchaseAcknowledgesAndRefreshesCurrentSupport() = runTest {
        val transaction = purchase(playID, order = "GPA.new")
        val service = loadedAnnual()
        gateway.launch = { FlowResult.Purchased(listOf(transaction)) }
        gateway.purchases = { listOf(transaction) }
        service.purchase(productID)
        assertThat(service.state.value.state).isEqualTo(PurchaseState.Thanked)
        assertThat(gateway.acknowledgeCount(transaction.purchaseToken)).isEqualTo(1)
        assertThat(service.state.value.currentProductID).isEqualTo(productID)
        assertThat(service.state.value.canPurchase).isFalse()
    }

    @Test
    fun verificationAndWrongProductNeverReportSuccess() = runTest {
        val service = annual()
        val unverified = purchase(playID, signature = "forged")
        assertThat(service.finish(unverified)).isFalse()
        val wrong = purchase("oshodiscourses.support.annual10")
        assertThat(service.finish(wrong, expectedProductID = productID)).isFalse()
        val tip = purchase("com.agraabhi.oshodiscourses.tip.small")
        assertThat(service.finish(tip)).isFalse()
        val pending = purchase(playID, status = PurchaseStatus.PENDING)
        assertThat(service.finish(pending)).isFalse()
        assertThat(gateway.acknowledged).isEmpty()

        gateway.purchases = { listOf(unverified) }
        assertThat(service.purchaseState(unverified, productID)).isInstanceOf(PurchaseState.Failed::class.java)
        assertThat(gateway.acknowledged).isEmpty()
    }

    @Test
    fun verifiedPurchaseWithoutCurrentPlanDoesNotReportSuccess() = runTest {
        val transaction = purchase(playID)
        val service = annual()
        gateway.purchases = { emptyList() }
        assertThat(service.purchaseState(transaction, productID)).isEqualTo(
            PurchaseState.Failed("Couldn't verify your subscription. Check your Google Play subscriptions before trying again."),
        )
        assertThat(gateway.acknowledgeCount(transaction.purchaseToken)).isEqualTo(1)
        assertThat(service.state.value.currentProductID).isNull()
    }

    @Test
    fun renewalAndRefundUpdatesRefreshStatusWithoutThankYouPopups() = runTest {
        var listed = listOf(subscribed())
        gateway.purchases = { listed }
        val service = annual()
        val renewal = purchase(playID, order = "GPA.sub..0")
        service.handleUpdate(renewal)
        assertThat(service.state.value.currentProductID).isEqualTo(productID)
        assertThat(service.state.value.state).isEqualTo(PurchaseState.Idle)

        listed = emptyList()
        service.refreshStatus()
        assertThat(service.state.value.currentProductID).isNull()
        assertThat(service.state.value.state).isEqualTo(PurchaseState.Idle)
        assertThat(service.state.value.canPurchase).isTrue()
        assertThat(gateway.acknowledgeCount(renewal.purchaseToken)).isEqualTo(1)
    }

    @Test
    fun statusRefreshAcknowledgesAPurchaseLeftUnacknowledged() = runTest {
        val unacknowledged = purchase(playID, order = "GPA.crash")
        gateway.purchases = { listOf(unacknowledged) }
        val service = annual()
        service.refreshStatus()
        service.refreshStatus()
        assertThat(gateway.acknowledgeCount(unacknowledged.purchaseToken)).isEqualTo(1)
        assertThat(service.state.value.currentProductID).isEqualTo(productID)
    }

    @Test
    fun delayedApprovalClearsPendingWithoutPresentingAnAlert() = runTest {
        val service = loadedAnnual()
        gateway.launch = { FlowResult.Purchased(listOf(purchase(playID, order = null, token = "t", status = PurchaseStatus.PENDING))) }
        service.purchase(productID)
        assertThat(service.state.value.state).isEqualTo(PurchaseState.Pending)

        val approved = purchase(playID, order = "GPA.approved", token = "t")
        gateway.purchases = { listOf(approved) }
        service.handleUpdate(approved)
        assertThat(service.state.value.currentProductID).isEqualTo(productID)
        assertThat(service.state.value.state).isEqualTo(PurchaseState.Idle)
        assertThat(service.state.value.pendingProductID).isNull()
    }

    @Test
    fun dismissingPendingDoesNotEnableOtherAmountsAfterRelaunch() = runTest {
        val service = loadedAnnual()
        gateway.launch = { FlowResult.Purchased(listOf(purchase(playID, order = null, token = "t", status = PurchaseStatus.PENDING))) }
        service.purchase(productID)
        service.dismissMessage()
        assertThat(service.state.value.state).isEqualTo(PurchaseState.Idle)
        assertThat(service.state.value.pendingProductID).isEqualTo(productID)
        assertThat(service.state.value.canPurchase).isFalse()

        // Play may not list a pending subscription; its absence alone must not unblock another amount.
        val relaunched = loadedAnnual()
        assertThat(relaunched.state.value.pendingProductID).isEqualTo(productID)
        assertThat(relaunched.state.value.canPurchase).isFalse()
        relaunched.purchase("com.agraabhi.oshodiscourses.support.annual10")
        assertThat(gateway.launches).isEqualTo(1)
        relaunched.clearDeclinedRequest()
        assertThat(relaunched.state.value.canPurchase).isTrue()
        assertThat(annual().state.value.pendingProductID).isNull()
    }

    @Test
    fun pendingRequestThatPlayListedThenDroppedIsCleared() = runTest {
        val pending = purchase(playID, order = null, token = "t", status = PurchaseStatus.PENDING)
        gateway.purchases = { listOf(pending) }
        val service = loadedAnnual()
        assertThat(service.state.value.pendingProductID).isEqualTo(productID)
        assertThat(service.state.value.canPurchase).isFalse()

        gateway.purchases = { emptyList() }
        val relaunched = annual()
        assertThat(relaunched.state.value.pendingProductID).isEqualTo(productID)
        relaunched.refreshStatus()
        assertThat(relaunched.state.value.pendingProductID).isNull()
        assertThat(relaunched.state.value.canPurchase).isTrue()
    }

    @Test
    fun alreadyOwnedRefreshesStatusInsteadOfFailing() = runTest {
        val service = loadedAnnual()
        gateway.launch = { FlowResult.Failed(BillingError.ALREADY_OWNED) }
        gateway.purchases = { listOf(subscribed()) }
        service.purchase(productID)
        assertThat(service.state.value.state).isEqualTo(PurchaseState.Idle)
        assertThat(service.state.value.currentProductID).isEqualTo(productID)
    }

    @Test
    fun restoreReportsFoundMissingAndFailedStates() = runTest {
        var listed: List<StorePurchase>? = listOf(subscribed())
        gateway.purchases = { listed ?: throw BillingException(BillingError.NETWORK) }
        val service = annual()
        service.restore()
        assertThat(service.state.value.currentProductID).isEqualTo(productID)
        assertThat(service.state.value.restoreMessage).isEqualTo("Your yearly support subscription is restored. Thank you.")

        listed = emptyList()
        service.restore()
        assertThat(service.state.value.currentProductID).isNull()
        assertThat(service.state.value.restoreMessage).isEqualTo("No current yearly support subscription was found.")

        listed = null
        service.restore()
        assertThat(service.state.value.state)
            .isEqualTo(PurchaseState.Failed("Couldn't restore your subscription. Please try again later."))
        assertThat(service.state.value.restoreMessage).isNull()
        assertThat(service.state.value.isRestoring).isFalse()
    }

    @Test
    fun overlappingStatusRequestsWaitForTheFreshSnapshot() = runTest {
        val entered = Gate()
        val release = Gate()
        val secondEntered = Gate()
        var calls = 0
        gateway.purchases = {
            calls++
            if (calls == 1) {
                entered.open()
                release.await()
                emptyList()
            } else {
                listOf(subscribed())
            }
        }
        val service = annual()
        val first = launch { service.refreshStatus() }
        entered.await()
        var secondSaw: String? = null
        val second = launch {
            secondEntered.open()
            service.refreshStatus()
            secondSaw = service.state.value.currentProductID
        }
        secondEntered.await()
        assertThat(service.state.value.isRefreshingStatus).isTrue()
        release.open()
        first.join()
        second.join()
        assertThat(secondSaw).isEqualTo(productID)
        assertThat(calls).isEqualTo(2)
        assertThat(service.state.value.isRefreshingStatus).isFalse()
    }
}
