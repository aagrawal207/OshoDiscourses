package com.agraabhi.oshodiscourses.billing

import kotlinx.coroutines.flow.Flow

/**
 * The slice of Play Billing the support store uses. [PlayBillingGateway] wraps `BillingClient`;
 * tests supply a fake, because Play's `Purchase` and `ProductDetails` cannot be built in unit tests.
 */
internal interface BillingGateway {
    /** Purchases Play delivers outside a launched flow: approvals of pending payments, promo codes. */
    val updates: Flow<List<StorePurchase>>

    /** Products Play knows about; unknown or inactive IDs are left out. Throws [BillingException]. */
    suspend fun queryProducts(kind: ProductKind, ids: List<String>): List<StoreProduct>

    /** Unconsumed one-time purchases, or current subscriptions including suspended ones. Throws [BillingException]. */
    suspend fun queryPurchases(kind: ProductKind): List<StorePurchase>

    /** Shows Play's purchase sheet on the foreground activity and waits for its result. */
    suspend fun launchPurchase(product: StoreProduct): FlowResult

    /** Throws [BillingException]; an already consumed token counts as success. */
    suspend fun consume(purchaseToken: String)

    /** Throws [BillingException]. */
    suspend fun acknowledge(purchaseToken: String)
}

internal enum class ProductKind { ONE_TIME, SUBSCRIPTION }

internal data class StoreProduct(
    /** The Play product ID, which can differ from the contract ID (see [SupportProducts]). */
    val id: String,
    val kind: ProductKind,
    val name: String,
    val description: String,
    val displayPrice: String,
    val priceMicros: Long,
    /** ISO 8601 period of the recurring phase; null for one-time products. */
    val billingPeriod: String? = null,
    val offerToken: String? = null,
)

internal enum class PurchaseStatus { PURCHASED, PENDING, UNSPECIFIED }

internal data class StorePurchase(
    /** Null while a payment is pending. */
    val orderId: String?,
    val purchaseToken: String,
    val products: List<String>,
    val status: PurchaseStatus,
    val isAcknowledged: Boolean = false,
    /** A subscription on account hold or paused: still owned, but its payment is being retried. */
    val isSuspended: Boolean = false,
    val originalJson: String = "",
    val signature: String = "",
) {
    /** Play order IDs identify one charge; the token is the fallback for test purchases without one. */
    val ledgerKey: String get() = orderId?.takeIf { it.isNotBlank() } ?: purchaseToken
}

internal sealed interface FlowResult {
    data class Purchased(val purchases: List<StorePurchase>) : FlowResult

    data object Cancelled : FlowResult

    data class Failed(val error: BillingError) : FlowResult
}

internal enum class BillingError { ALREADY_OWNED, ITEM_UNAVAILABLE, BILLING_UNAVAILABLE, NO_ACTIVITY, NETWORK, OTHER }

internal class BillingException(val error: BillingError, message: String? = null) : Exception(message)
