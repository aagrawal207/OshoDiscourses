package com.agraabhi.oshodiscourses.billing

import com.agraabhi.oshodiscourses.billing.FakeBillingGateway.Companion.purchase
import com.agraabhi.oshodiscourses.core.domain.support.PurchaseState
import com.agraabhi.oshodiscourses.core.domain.support.SupportStore
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class PlaySupportStoreTest {
    @get:Rule val folder = TemporaryFolder()

    private val gateway = FakeBillingGateway()

    // Background-scope work is invisible to advanceUntilIdle, so tests drain it with runCurrent.
    private fun TestScope.store(): PlaySupportStore {
        val dispatcher = StandardTestDispatcher(testScheduler)
        return PlaySupportStore(gateway, TestVerifier, folder.root, backgroundScope, dispatcher, io = dispatcher)
    }

    @Test
    fun playProductIDsFollowPlayConsoleRules() {
        // Play: start with a lowercase letter or digit; a-z, 0-9, '_' and '.'; subscriptions at most 40 characters.
        val rule = Regex("^[a-z0-9][a-z0-9_.]*$")
        for (id in SupportProducts.tipIDs + SupportProducts.annualPlayIDs.values) assertThat(id).matches(rule.pattern)
        for (id in SupportProducts.annualPlayIDs.values) assertThat(id.length).isAtMost(40)
        assertThat(SupportProducts.tipIDs).isEqualTo(SupportStore.TIP_PRODUCTS.map { it.id })
        assertThat(SupportProducts.ANNUAL_BASE_PLAN_ID).matches("^[a-z0-9][a-z0-9-]*$")
    }

    @Test
    fun startupRecoversUnconsumedTipsAndReadsSubscriptionStatus() = runTest {
        gateway.purchases = { kind ->
            when (kind) {
                ProductKind.ONE_TIME -> listOf(purchase("com.agraabhi.oshodiscourses.tip.large", order = "GPA.closed"))
                ProductKind.SUBSCRIPTION -> listOf(purchase("oshodiscourses.support.annual10", order = "GPA.sub", acknowledged = true))
            }
        }
        val store = store()
        runCurrent()
        assertThat(store.tipJar.value.tipCount).isEqualTo(1)
        assertThat(store.tipJar.value.state).isEqualTo(PurchaseState.Thanked)
        assertThat(store.annualSupport.value.currentProductID).isEqualTo("com.agraabhi.oshodiscourses.support.annual10")
        assertThat(store.annualSupport.value.statusIsCurrent).isTrue()
    }

    @Test
    fun backgroundUpdatesReachTheRightService() = runTest {
        val store = store()
        runCurrent()
        gateway.purchases = { kind ->
            if (kind == ProductKind.SUBSCRIPTION) listOf(purchase("oshodiscourses.support.annual5", order = "GPA.s")) else emptyList()
        }
        gateway.updates.emit(
            listOf(
                purchase("com.agraabhi.oshodiscourses.tip.small", order = "GPA.t"),
                purchase("oshodiscourses.support.annual5", order = "GPA.s"),
            ),
        )
        runCurrent()
        assertThat(store.tipJar.value.tipCount).isEqualTo(1)
        assertThat(gateway.consumeCount("token-GPA.t")).isEqualTo(1)
        assertThat(gateway.acknowledgeCount("token-GPA.s")).isEqualTo(1)
        assertThat(store.annualSupport.value.currentProductID).isEqualTo("com.agraabhi.oshodiscourses.support.annual5")
        assertThat(store.annualSupport.value.state).isEqualTo(PurchaseState.Idle)
    }

    @Test
    fun contractCallsDriveTheFlowEndToEnd() = runTest {
        val store = store()
        store.loadTipProducts()
        assertThat(store.tipJar.value.products.map { it.name })
            .containsExactly("Small tip", "Generous tip", "Big tip", "Grand tip", "Patron tip").inOrder()
        gateway.launch = { FlowResult.Purchased(listOf(purchase(it.id, order = "GPA.buy"))) }
        store.purchaseTip("com.agraabhi.oshodiscourses.tip.grand")
        assertThat(store.tipJar.value.state).isEqualTo(PurchaseState.Thanked)
        store.dismissTipMessage()
        assertThat(store.tipJar.value.canPurchase).isTrue()

        store.loadAnnualProducts()
        assertThat(store.annualSupport.value.products.map { it.name })
            .containsExactly("Small yearly support", "Generous yearly support", "Extra yearly support").inOrder()
        assertThat(store.annualSupport.value.canPurchase).isTrue()
        val sub = purchase("oshodiscourses.support.annual15", order = "GPA.yearly")
        gateway.launch = { FlowResult.Purchased(listOf(sub)) }
        gateway.purchases = { kind -> if (kind == ProductKind.SUBSCRIPTION) listOf(sub) else emptyList() }
        store.purchaseAnnual("com.agraabhi.oshodiscourses.support.annual15")
        assertThat(store.annualSupport.value.state).isEqualTo(PurchaseState.Thanked)
        assertThat(store.annualSupport.value.currentProductID).isEqualTo("com.agraabhi.oshodiscourses.support.annual15")
        store.dismissAnnualMessage()
        store.restore()
        assertThat(store.annualSupport.value.restoreMessage).isEqualTo("Your yearly support subscription is restored. Thank you.")
    }
}
