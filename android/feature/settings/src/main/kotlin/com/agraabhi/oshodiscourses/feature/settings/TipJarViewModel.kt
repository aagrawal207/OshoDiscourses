package com.agraabhi.oshodiscourses.feature.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.agraabhi.oshodiscourses.core.domain.engagement.EngagementService
import com.agraabhi.oshodiscourses.core.domain.support.AnnualSupportState
import com.agraabhi.oshodiscourses.core.domain.support.PurchaseState
import com.agraabhi.oshodiscourses.core.domain.support.SupportProduct
import com.agraabhi.oshodiscourses.core.domain.support.SupportStore
import com.agraabhi.oshodiscourses.core.domain.support.TipJarState
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import java.util.UUID

/** One purchasable row, tip or yearly plan. */
internal data class SupportRow(
    val product: SupportProduct,
    val isAnnual: Boolean,
    val kind: String,
    val price: String,
    val isPurchasing: Boolean,
    val enabled: Boolean,
)

internal data class SupportMessage(val title: String, val body: String)

internal data class TipJarUiState(
    val tips: TipJarState = TipJarState(),
    val annual: AnnualSupportState = AnnualSupportState(),
) {
    val isLoading: Boolean get() = tips.isLoading || annual.isLoading

    val rows: List<SupportRow>
        get() = orderedProducts(tips.products, annual.products).map { (product, isAnnual) ->
            val kind = when {
                !isAnnual -> "One-time tip"
                annual.currentProductID == product.id -> "Current yearly plan"
                annual.pendingProductID == product.id -> "Awaiting approval"
                else -> "Renews yearly · Cancel anytime"
            }
            val purchasing = tips.state == PurchaseState.Purchasing(product.id) || annual.state == PurchaseState.Purchasing(product.id)
            val enabled = if (isAnnual) {
                annual.canPurchase && !tips.isPurchasing && tips.state == PurchaseState.Idle
            } else {
                tips.canPurchase && !annual.isBusy && annual.state == PurchaseState.Idle
            }
            SupportRow(product, isAnnual, kind, if (isAnnual) "${product.displayPrice} / year" else product.displayPrice, purchasing, enabled)
        }

    val tipCountFooter: String?
        get() = when (tips.tipCount) {
            0 -> null
            1 -> "One tip recorded on this device. Thank you."
            else -> "${tips.tipCount} tips recorded on this device. Thank you."
        }

    val isPending: Boolean get() = tips.state == PurchaseState.Pending || annual.state == PurchaseState.Pending

    /** Yearly outcomes win over tips, as on iOS, so only one alert shows at a time. */
    val message: SupportMessage?
        get() {
            when (val s = annual.state) {
                PurchaseState.Thanked -> return SupportMessage(
                    "Thank you",
                    "Your yearly support helps me keep improving Osho Talks. Every feature stays free for everyone.",
                )
                is PurchaseState.Failed -> return SupportMessage("Couldn't confirm subscription", s.message)
                else -> Unit
            }
            return when (val s = tips.state) {
                PurchaseState.Thanked -> SupportMessage("Thank you", "Your tip keeps this app going. Enjoy the talks.")
                is PurchaseState.Failed -> SupportMessage("Couldn't confirm tip", s.message)
                else -> null
            }
        }

    companion object {
        /**
         * The US price ladder (TipJar.storekit), used when a product has no price in micros.
         * Play keeps regional prices in the same order as the US ones.
         */
        private val PRICE_ORDER = listOf(
            "tip.small", "tip.medium", "support.annual5", "tip.large", "support.annual10", "support.annual15", "tip.grand", "tip.patron",
        ).map { "com.agraabhi.oshodiscourses.$it" }

        /** iOS sorts by price with tips first at an equal price; unknown products go last. */
        fun orderedProducts(tips: List<SupportProduct>, annual: List<SupportProduct>): List<Pair<SupportProduct, Boolean>> {
            val all = tips.map { it to false } + annual.map { it to true }
            val byPrice = all.all { (p, _) -> p.priceMicros != null }
            val rank: (SupportProduct) -> Long = if (byPrice) {
                { it.priceMicros ?: Long.MAX_VALUE }
            } else {
                { p -> PRICE_ORDER.indexOf(p.id).let { if (it < 0) Long.MAX_VALUE else it.toLong() } }
            }
            return all.sortedWith(
                compareBy<Pair<SupportProduct, Boolean>> { (p, _) -> rank(p) }
                    .thenBy { (_, isAnnual) -> isAnnual }
                    .thenBy { (p, _) -> p.id },
            )
        }
    }
}

/** iOS `TipJarView` over `TipJarService` and `AnnualSupportService`, here one `SupportStore`. */
internal class TipJarViewModel(
    private val store: SupportStore,
    private val engagement: EngagementService,
) : ViewModel() {
    private val owner = "tipJar-${UUID.randomUUID()}"

    val state: StateFlow<TipJarUiState> = combine(store.tipJar, store.annualSupport, ::TipJarUiState)
        .stateIn(viewModelScope, SharingStarted.Eagerly, TipJarUiState(store.tipJar.value, store.annualSupport.value))

    /** Loads both product sets in parallel, then checks the subscription so yearly rows can enable. */
    fun load() {
        viewModelScope.launch { store.loadTipProducts() }
        viewModelScope.launch {
            store.loadAnnualProducts()
            store.refreshAnnualStatus()
        }
    }

    fun loadTips() = viewModelScope.launch { store.loadTipProducts() }

    fun loadAnnual() = viewModelScope.launch { store.loadAnnualProducts() }

    fun refreshStatus() = viewModelScope.launch { store.refreshAnnualStatus() }

    fun purchase(row: SupportRow) = viewModelScope.launch {
        if (row.isAnnual) store.purchaseAnnual(row.product.id) else store.purchaseTip(row.product.id)
    }

    fun restore() = viewModelScope.launch { store.restore() }

    fun dismissMessages() = viewModelScope.launch {
        store.dismissTipMessage()
        store.dismissAnnualMessage()
    }

    /** The open sheet blocks the Home support card and rating asks. */
    fun onShown() = engagement.registerSupportSheet(owner)

    fun onHidden() = engagement.unregisterSupportSheet(owner)

    override fun onCleared() = engagement.unregisterSupportSheet(owner)
}
