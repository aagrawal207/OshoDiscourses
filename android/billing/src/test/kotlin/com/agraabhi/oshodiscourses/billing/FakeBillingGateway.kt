package com.agraabhi.oshodiscourses.billing

import kotlinx.coroutines.flow.MutableSharedFlow

/** Scriptable Play: each hook can suspend on a gate to reproduce overlapping deliveries. */
internal class FakeBillingGateway : BillingGateway {
    override val updates = MutableSharedFlow<List<StorePurchase>>(extraBufferCapacity = 16)

    var products: suspend (ProductKind, List<String>) -> List<StoreProduct> = { kind, ids -> catalog(kind, ids) }
    var purchases: suspend (ProductKind) -> List<StorePurchase> = { emptyList() }
    var launch: suspend (StoreProduct) -> FlowResult = { FlowResult.Cancelled }
    var onConsume: suspend (String) -> Unit = {}
    var onAcknowledge: suspend (String) -> Unit = {}

    val consumed = mutableListOf<String>()
    val acknowledged = mutableListOf<String>()
    var launches = 0
        private set
    var productQueries = 0
        private set
    var purchaseQueries = 0
        private set

    override suspend fun queryProducts(kind: ProductKind, ids: List<String>): List<StoreProduct> {
        productQueries++
        return products(kind, ids)
    }

    override suspend fun queryPurchases(kind: ProductKind): List<StorePurchase> {
        purchaseQueries++
        // Play reports acknowledgement on the next query.
        return purchases(kind).map { if (it.purchaseToken in acknowledged) it.copy(isAcknowledged = true) else it }
    }

    override suspend fun launchPurchase(product: StoreProduct): FlowResult {
        launches++
        return launch(product)
    }

    override suspend fun consume(purchaseToken: String) {
        consumed += purchaseToken
        onConsume(purchaseToken)
    }

    override suspend fun acknowledge(purchaseToken: String) {
        acknowledged += purchaseToken
        onAcknowledge(purchaseToken)
    }

    fun consumeCount(token: String): Int = consumed.count { it == token }

    fun acknowledgeCount(token: String): Int = acknowledged.count { it == token }

    companion object {
        private val tipPrices = mapOf(
            "com.agraabhi.oshodiscourses.tip.small" to ("Small tip" to 3),
            "com.agraabhi.oshodiscourses.tip.medium" to ("Generous tip" to 5),
            "com.agraabhi.oshodiscourses.tip.large" to ("Big tip" to 10),
            "com.agraabhi.oshodiscourses.tip.grand" to ("Grand tip" to 25),
            "com.agraabhi.oshodiscourses.tip.patron" to ("Patron tip" to 50),
        )
        private val annualPrices = mapOf(
            "oshodiscourses.support.annual5" to ("Small yearly support" to 5),
            "oshodiscourses.support.annual10" to ("Generous yearly support" to 10),
            "oshodiscourses.support.annual15" to ("Extra yearly support" to 15),
        )

        fun tip(id: String, kind: ProductKind = ProductKind.ONE_TIME): StoreProduct {
            val (name, dollars) = tipPrices[id] ?: (id to 1)
            return StoreProduct(id, kind, name, "A tip.", "$$dollars.00", dollars * 1_000_000L)
        }

        fun annual(playID: String, period: String? = "P1Y"): StoreProduct {
            val (name, dollars) = annualPrices[playID] ?: (playID to 1)
            return StoreProduct(
                playID, ProductKind.SUBSCRIPTION, name, "Optional support for ongoing app development.",
                "$$dollars.00", dollars * 1_000_000L, billingPeriod = period, offerToken = "offer-$playID",
            )
        }

        fun catalog(kind: ProductKind, ids: List<String>): List<StoreProduct> = when (kind) {
            ProductKind.ONE_TIME -> ids.filter { it in tipPrices }.map { tip(it) }
            ProductKind.SUBSCRIPTION -> ids.filter { it in annualPrices }.map { annual(it) }
        }

        fun purchase(
            product: String,
            order: String? = "GPA.0001",
            token: String = "token-${order ?: product}",
            status: PurchaseStatus = PurchaseStatus.PURCHASED,
            acknowledged: Boolean = false,
            suspended: Boolean = false,
            signature: String = "valid",
        ) = StorePurchase(order, token, listOf(product), status, acknowledged, suspended, "{\"productId\":\"$product\"}", signature)
    }
}

/** Accepts purchases whose signature is "valid", standing in for Play's RSA check. */
internal val TestVerifier = PurchaseVerifier { it.signature == "valid" }
