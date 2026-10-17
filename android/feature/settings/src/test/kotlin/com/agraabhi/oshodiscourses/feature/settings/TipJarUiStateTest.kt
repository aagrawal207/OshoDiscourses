package com.agraabhi.oshodiscourses.feature.settings

import com.agraabhi.oshodiscourses.core.domain.support.AnnualSupportState
import com.agraabhi.oshodiscourses.core.domain.support.PurchaseState
import com.agraabhi.oshodiscourses.core.domain.support.SupportProduct
import com.agraabhi.oshodiscourses.core.domain.support.TipJarState
import com.agraabhi.oshodiscourses.core.domain.sync.SyncStatus
import com.google.common.truth.Truth.assertThat
import org.junit.Test

class TipJarUiStateTest {
    private val loaded = TipJarUiState(
        TipJarState(products = IosProducts.tips),
        AnnualSupportState(products = IosProducts.annual, statusIsCurrent = true),
    )

    @Test
    fun productsInterleaveByPriceWithTipsFirstAtEqualPrice() {
        assertThat(loaded.rows.map { it.product.name }).containsExactly(
            "Small tip",
            "Generous tip",
            "Small yearly support",
            "Big tip",
            "Generous yearly support",
            "Extra yearly support",
            "Grand tip",
            "Patron tip",
        ).inOrder()
        assertThat(loaded.rows[2].price).isEqualTo("$4.99 / year")
        assertThat(loaded.rows[2].kind).isEqualTo("Renews yearly · Cancel anytime")
        assertThat(loaded.rows[0].kind).isEqualTo("One-time tip")
    }

    @Test
    fun unknownProductsSortLast() {
        val extra = SupportProduct("com.example.other", "Other", "", "$1.00")
        val rows = TipJarUiState.orderedProducts(IosProducts.tips + extra, emptyList())
        assertThat(rows.last().first).isEqualTo(extra)
    }

    @Test
    fun yearlyRowsNeedACurrentStatusAndNoPlan() {
        val unchecked = loaded.copy(annual = loaded.annual.copy(statusIsCurrent = false))
        assertThat(unchecked.rows.filter { it.isAnnual }.none { it.enabled }).isTrue()
        assertThat(unchecked.rows.filterNot { it.isAnnual }.all { it.enabled }).isTrue()

        val subscribed = loaded.copy(annual = loaded.annual.copy(currentProductID = IosProducts.annual[1].id))
        assertThat(subscribed.rows.first { it.product.id == IosProducts.annual[1].id }.kind).isEqualTo("Current yearly plan")
        assertThat(subscribed.rows.filter { it.isAnnual }.none { it.enabled }).isTrue()
    }

    @Test
    fun aPurchaseInFlightLocksTheOtherKind() {
        val buying = loaded.copy(tips = loaded.tips.copy(isPurchasing = true, state = PurchaseState.Purchasing(IosProducts.tips[0].id)))
        assertThat(buying.rows.first().isPurchasing).isTrue()
        assertThat(buying.rows.filter { it.isAnnual }.none { it.enabled }).isTrue()
        assertThat(buying.rows.filterNot { it.isAnnual }.none { it.enabled }).isTrue()
    }

    @Test
    fun yearlyOutcomeWinsOverATipAndPendingShowsTheBar() {
        val both = loaded.copy(
            tips = loaded.tips.copy(state = PurchaseState.Thanked),
            annual = loaded.annual.copy(state = PurchaseState.Failed("Couldn't verify your subscription.")),
        )
        assertThat(both.message).isEqualTo(SupportMessage("Couldn't confirm subscription", "Couldn't verify your subscription."))
        assertThat(loaded.copy(tips = loaded.tips.copy(state = PurchaseState.Pending)).isPending).isTrue()
        assertThat(loaded.message).isNull()
    }

    @Test
    fun tipCountFooterPluralises() {
        assertThat(loaded.tipCountFooter).isNull()
        assertThat(loaded.copy(tips = loaded.tips.copy(tipCount = 1)).tipCountFooter).isEqualTo("One tip recorded on this device. Thank you.")
        assertThat(loaded.copy(tips = loaded.tips.copy(tipCount = 4)).tipCountFooter).isEqualTo("4 tips recorded on this device. Thank you.")
    }

    @Test
    fun manageSubscriptionsLinksToPlay() {
        assertThat(manageSubscriptionsUrl("com.agraabhi.oshodiscourses", null))
            .isEqualTo("https://play.google.com/store/account/subscriptions?package=com.agraabhi.oshodiscourses")
        assertThat(manageSubscriptionsUrl("p", "s")).endsWith("&sku=s")
    }

    @Test
    fun syncSubtitles() {
        assertThat(SettingsUiState(sync = SyncStatus.Idle).syncSubtitle).isEqualTo("Not connected")
        assertThat(SettingsUiState(sync = SyncStatus.Idle).isSyncConnected).isFalse()
        assertThat(SettingsUiState(sync = SyncStatus.Syncing).syncSubtitle).isEqualTo("Syncing…")
        assertThat(SettingsUiState(sync = SyncStatus.UpToDate(1)).isSyncConnected).isTrue()
        assertThat(SettingsUiState(sync = SyncStatus.Failed("x")).syncSubtitle).isEqualTo("x")
    }
}
