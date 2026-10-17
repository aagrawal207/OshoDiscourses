package com.agraabhi.oshodiscourses.billing

import android.app.Activity
import android.content.Context
import com.android.billingclient.api.AcknowledgePurchaseParams
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClient.BillingResponseCode
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingFlowParams
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.ConsumeParams
import com.android.billingclient.api.PendingPurchasesParams
import com.android.billingclient.api.ProductDetails
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.PurchasesUpdatedListener
import com.android.billingclient.api.QueryProductDetailsParams
import com.android.billingclient.api.QueryPurchasesParams
import com.android.billingclient.api.acknowledgePurchase
import com.android.billingclient.api.consumePurchase
import com.android.billingclient.api.queryProductDetails
import com.android.billingclient.api.queryPurchasesAsync
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.resume
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** [BillingGateway] over Play Billing. Purchase sheets open on the activity [activityProvider] returns. */
internal class PlayBillingGateway(
    context: Context,
    private val activityProvider: () -> Activity?,
) : BillingGateway, PurchasesUpdatedListener {
    private val client: BillingClient = BillingClient.newBuilder(context.applicationContext)
        .setListener(this)
        .enablePendingPurchases(PendingPurchasesParams.newBuilder().enableOneTimeProducts().build())
        .enableAutoServiceReconnection()
        .build()

    private val connection = Mutex()
    private val details = ConcurrentHashMap<String, ProductDetails>()
    private val updatesFlow = MutableSharedFlow<List<StorePurchase>>(extraBufferCapacity = 16)
    override val updates: Flow<List<StorePurchase>> = updatesFlow

    private class InFlight(val productID: String, val result: CompletableDeferred<FlowResult> = CompletableDeferred())

    @Volatile private var inFlight: InFlight? = null

    private suspend fun connect() = connection.withLock {
        if (client.isReady) return@withLock
        val result = suspendCancellableCoroutine { continuation ->
            client.startConnection(object : BillingClientStateListener {
                // Auto reconnection calls this again later; only the first call answers this request.
                override fun onBillingSetupFinished(result: BillingResult) {
                    if (continuation.isActive) continuation.resume(result)
                }

                override fun onBillingServiceDisconnected() = Unit
            })
        }
        result.throwIfFailed()
    }

    override suspend fun queryProducts(kind: ProductKind, ids: List<String>): List<StoreProduct> {
        connect()
        val products = ids.map {
            QueryProductDetailsParams.Product.newBuilder().setProductId(it).setProductType(kind.playType).build()
        }
        val result = client.queryProductDetails(QueryProductDetailsParams.newBuilder().setProductList(products).build())
        result.billingResult.throwIfFailed()
        val list = result.productDetailsList.orEmpty()
        list.forEach { details[it.productId] = it }
        return list.mapNotNull { it.toStoreProduct() }
    }

    override suspend fun queryPurchases(kind: ProductKind): List<StorePurchase> {
        connect()
        val params = QueryPurchasesParams.newBuilder().setProductType(kind.playType)
        // Account hold and pause are iOS's billing retry: the listener still owns the plan.
        if (kind == ProductKind.SUBSCRIPTION) params.includeSuspendedSubscriptions(true)
        val result = client.queryPurchasesAsync(params.build())
        result.billingResult.throwIfFailed()
        return result.purchasesList.map { it.toStorePurchase() }
    }

    override suspend fun launchPurchase(product: StoreProduct): FlowResult {
        try {
            connect()
        } catch (e: BillingException) {
            return FlowResult.Failed(e.error)
        }
        val productDetails = details[product.id] ?: return FlowResult.Failed(BillingError.ITEM_UNAVAILABLE)
        val activity = activityProvider() ?: return FlowResult.Failed(BillingError.NO_ACTIVITY)
        val params = BillingFlowParams.ProductDetailsParams.newBuilder().setProductDetails(productDetails)
        product.offerToken?.let(params::setOfferToken)
        val flowParams = BillingFlowParams.newBuilder().setProductDetailsParamsList(listOf(params.build())).build()
        val flight = InFlight(product.id)
        inFlight = flight
        try {
            val launch = withContext(Dispatchers.Main) { client.launchBillingFlow(activity, flowParams) }
            if (launch.responseCode != BillingResponseCode.OK) return launch.toFlowResult()
            return flight.result.await()
        } finally {
            if (inFlight === flight) inFlight = null
        }
    }

    override fun onPurchasesUpdated(result: BillingResult, purchases: List<Purchase>?) {
        val converted = purchases.orEmpty().map { it.toStorePurchase() }
        val flight = inFlight
        if (flight == null) {
            if (result.responseCode == BillingResponseCode.OK) emit(converted)
            return
        }
        // Play can deliver an unrelated approval while a sheet is open; keep it out of this flow.
        val (mine, others) = converted.partition { flight.productID in it.products }
        when {
            result.responseCode != BillingResponseCode.OK -> flight.result.complete(result.toFlowResult())
            mine.isNotEmpty() -> flight.result.complete(FlowResult.Purchased(mine))
        }
        if (result.responseCode == BillingResponseCode.OK) emit(others)
    }

    private fun emit(purchases: List<StorePurchase>) {
        if (purchases.isNotEmpty()) updatesFlow.tryEmit(purchases)
    }

    override suspend fun consume(purchaseToken: String) {
        connect()
        val result = client.consumePurchase(ConsumeParams.newBuilder().setPurchaseToken(purchaseToken).build())
        if (result.billingResult.responseCode == BillingResponseCode.ITEM_NOT_OWNED) return
        result.billingResult.throwIfFailed()
    }

    override suspend fun acknowledge(purchaseToken: String) {
        connect()
        client.acknowledgePurchase(AcknowledgePurchaseParams.newBuilder().setPurchaseToken(purchaseToken).build())
            .throwIfFailed()
    }
}

private val ProductKind.playType: String
    get() = when (this) {
        ProductKind.ONE_TIME -> BillingClient.ProductType.INAPP
        ProductKind.SUBSCRIPTION -> BillingClient.ProductType.SUBS
    }

private fun BillingResult.billingError(): BillingError = when (responseCode) {
    BillingResponseCode.ITEM_ALREADY_OWNED -> BillingError.ALREADY_OWNED
    BillingResponseCode.ITEM_UNAVAILABLE -> BillingError.ITEM_UNAVAILABLE
    BillingResponseCode.BILLING_UNAVAILABLE, BillingResponseCode.FEATURE_NOT_SUPPORTED -> BillingError.BILLING_UNAVAILABLE
    BillingResponseCode.NETWORK_ERROR, BillingResponseCode.SERVICE_UNAVAILABLE,
    BillingResponseCode.SERVICE_DISCONNECTED -> BillingError.NETWORK
    else -> BillingError.OTHER
}

private fun BillingResult.throwIfFailed() {
    if (responseCode != BillingResponseCode.OK) throw BillingException(billingError(), debugMessage)
}

private fun BillingResult.toFlowResult(): FlowResult =
    if (responseCode == BillingResponseCode.USER_CANCELED) FlowResult.Cancelled else FlowResult.Failed(billingError())

private fun Purchase.toStorePurchase() = StorePurchase(
    orderId = orderId,
    purchaseToken = purchaseToken,
    products = products,
    status = when (purchaseState) {
        Purchase.PurchaseState.PURCHASED -> PurchaseStatus.PURCHASED
        Purchase.PurchaseState.PENDING -> PurchaseStatus.PENDING
        else -> PurchaseStatus.UNSPECIFIED
    },
    isAcknowledged = isAcknowledged,
    isSuspended = isSuspended,
    originalJson = originalJson,
    signature = signature,
)

private fun ProductDetails.toStoreProduct(): StoreProduct? = when (productType) {
    BillingClient.ProductType.INAPP -> {
        val offer = oneTimePurchaseOfferDetails ?: oneTimePurchaseOfferDetailsList?.firstOrNull()
        offer?.let {
            StoreProduct(productId, ProductKind.ONE_TIME, name, description, it.formattedPrice, it.priceAmountMicros, offerToken = it.offerToken)
        }
    }
    BillingClient.ProductType.SUBS -> {
        val offers = subscriptionOfferDetails.orEmpty().filter { it.offerId == null }
        val offer = offers.firstOrNull { it.basePlanId == SupportProducts.ANNUAL_BASE_PLAN_ID } ?: offers.firstOrNull()
        val phase = offer?.pricingPhases?.pricingPhaseList?.lastOrNull()
        if (offer == null || phase == null) {
            null
        } else {
            StoreProduct(
                id = productId,
                kind = ProductKind.SUBSCRIPTION,
                name = name,
                description = description,
                displayPrice = phase.formattedPrice,
                priceMicros = phase.priceAmountMicros,
                billingPeriod = phase.billingPeriod.takeIf {
                    phase.recurrenceMode == ProductDetails.RecurrenceMode.INFINITE_RECURRING
                },
                offerToken = offer.offerToken,
            )
        }
    }
    else -> null
}
