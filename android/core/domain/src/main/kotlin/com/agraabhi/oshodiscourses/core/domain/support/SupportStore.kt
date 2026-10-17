package com.agraabhi.oshodiscourses.core.domain.support

import kotlinx.coroutines.flow.StateFlow

/**
 * Optional tips (consumables that unlock nothing) and yearly support subscriptions through
 * Google Play Billing (iOS `TipJarService` + `AnnualSupportService`). Purchases are
 * acknowledged only after they are recorded, and deliveries are deduplicated by order id.
 * The implementation launches billing flows on the foreground activity that `:app` tracks.
 */
interface SupportStore {
    val tipJar: StateFlow<TipJarState>
    val annualSupport: StateFlow<AnnualSupportState>

    suspend fun loadTipProducts()

    suspend fun purchaseTip(productID: String)

    /** Clears a thanked, pending or failed message back to idle. */
    suspend fun dismissTipMessage()

    suspend fun loadAnnualProducts()

    suspend fun refreshAnnualStatus()

    suspend fun purchaseAnnual(productID: String)

    suspend fun restore()

    suspend fun dismissAnnualMessage()

    /**
     * Forgets a yearly purchase the listener declined or abandoned, so Settings can offer it again
     * (iOS `AnnualSupportService.clearDeclinedRequest`). Stores without that memory do nothing.
     */
    suspend fun clearDeclinedRequest() {}

    companion object {
        /** In display order. Names and prices come from Play; these are the US base prices. */
        val TIP_PRODUCTS: List<SupportProductInfo> = listOf(
            SupportProductInfo("com.agraabhi.oshodiscourses.tip.small", "Small tip", "US$3"),
            SupportProductInfo("com.agraabhi.oshodiscourses.tip.medium", "Generous tip", "US$5"),
            SupportProductInfo("com.agraabhi.oshodiscourses.tip.large", "Big tip", "US$10"),
            SupportProductInfo("com.agraabhi.oshodiscourses.tip.grand", "Grand tip", "US$25"),
            SupportProductInfo("com.agraabhi.oshodiscourses.tip.patron", "Patron tip", "US$50"),
        )

        val ANNUAL_PRODUCT_IDS: List<String> = listOf(
            "com.agraabhi.oshodiscourses.support.annual5",
            "com.agraabhi.oshodiscourses.support.annual10",
            "com.agraabhi.oshodiscourses.support.annual15",
        )
    }
}

/** Static product facts; [basePrice] is reference only, never a button label. */
data class SupportProductInfo(val id: String, val name: String, val basePrice: String)

/** A product as Play returns it, with the storefront's formatted price. */
data class SupportProduct(
    val id: String,
    val name: String,
    val description: String,
    val displayPrice: String,
)

/** iOS `TipJarService.PurchaseState`, shared by tips and yearly support. */
sealed interface PurchaseState {
    data object Idle : PurchaseState
    data class Purchasing(val productID: String) : PurchaseState
    data object Thanked : PurchaseState

    /** Awaiting approval, e.g. a family-managed account or a slow payment method. */
    data object Pending : PurchaseState
    data class Failed(val message: String) : PurchaseState
}

data class TipJarState(
    val products: List<SupportProduct> = emptyList(),
    val loadError: String? = null,
    val isLoading: Boolean = false,
    val isPurchasing: Boolean = false,
    val state: PurchaseState = PurchaseState.Idle,
    /** Recorded tips on this device; consumables grant no entitlement. */
    val tipCount: Int = 0,
) {
    val canPurchase: Boolean get() = !isLoading && !isPurchasing && state == PurchaseState.Idle
}

data class AnnualSupportState(
    val products: List<SupportProduct> = emptyList(),
    val loadError: String? = null,
    val statusError: String? = null,
    /** The active subscription, if any. */
    val currentProductID: String? = null,
    val pendingProductID: String? = null,
    val restoreMessage: String? = null,
    val state: PurchaseState = PurchaseState.Idle,
    val isLoading: Boolean = false,
    val isRefreshingStatus: Boolean = false,
    val isPurchasing: Boolean = false,
    val isRestoring: Boolean = false,
    /** Whether [currentProductID] reflects a completed status check. */
    val statusIsCurrent: Boolean = false,
) {
    val isBusy: Boolean get() = isLoading || isRefreshingStatus || isPurchasing || isRestoring

    val canPurchase: Boolean
        get() = !isBusy && statusIsCurrent && currentProductID == null && pendingProductID == null && state == PurchaseState.Idle
}
