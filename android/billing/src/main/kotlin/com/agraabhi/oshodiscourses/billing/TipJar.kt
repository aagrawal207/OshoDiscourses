package com.agraabhi.oshodiscourses.billing

import com.agraabhi.oshodiscourses.core.domain.support.PurchaseState
import com.agraabhi.oshodiscourses.core.domain.support.SupportProduct
import com.agraabhi.oshodiscourses.core.domain.support.TipJarState
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.serialization.Serializable

/** Order IDs of recorded tips (iOS `tipJar.transactions`). */
@Serializable
internal data class TipLedger(val orderIDs: List<String> = emptyList())

/**
 * Consumable tips grant nothing (iOS `TipJarService`). Recording by order ID before consuming makes
 * every delivery of one charge count once. Callers confine it to one thread ([PlaySupportStore]).
 */
internal class TipJar(
    private val gateway: BillingGateway,
    private val verifier: PurchaseVerifier,
    private val ledger: JsonFileStore<TipLedger>,
) {
    enum class Source { PURCHASE, UPDATE, RECOVERY }

    enum class Outcome { COMPLETED, DUPLICATE, PENDING, UNVERIFIED, UNSUPPORTED, UNEXPECTED_PRODUCT }

    private val recorded: MutableSet<String> = ledger.read().orderIDs.toMutableSet()
    private val _state = MutableStateFlow(TipJarState(tipCount = recorded.size))
    val state: StateFlow<TipJarState> = _state

    private var storeProducts: Map<String, StoreProduct> = emptyMap()
    private val consumes = mutableMapOf<String, CompletableDeferred<Unit>>()

    suspend fun loadProducts() {
        val current = _state.value
        if (current.isLoading || current.isPurchasing) return
        _state.update { it.copy(isLoading = true, loadError = null) }
        try {
            val tips = gateway.queryProducts(ProductKind.ONE_TIME, SupportProducts.tipIDs)
                .filter { SupportProducts.isTip(it.id, it.kind) }
                .sortedBy { it.priceMicros }
            storeProducts = tips.associateBy { it.id }
            val error = when {
                tips.isEmpty() -> UNAVAILABLE_MESSAGE
                tips.size < SupportProducts.tipIDs.size -> PARTIAL_MESSAGE
                else -> null
            }
            _state.update { it.copy(products = tips.map(StoreProduct::toSupportProduct), loadError = error) }
        } catch (e: CancellationException) {
            _state.update { it.copy(loadError = INTERRUPTED_MESSAGE) }
            throw e
        } catch (_: Exception) {
            storeProducts = emptyMap()
            _state.update { it.copy(products = emptyList(), loadError = LOAD_FAILED_MESSAGE) }
        } finally {
            _state.update { it.copy(isLoading = false) }
        }
    }

    suspend fun purchase(productID: String) {
        if (!_state.value.canPurchase) return
        val product = storeProducts[productID]
        if (product == null || !SupportProducts.isTip(productID, product.kind)) {
            _state.update { it.copy(state = PurchaseState.Failed(NOT_AVAILABLE_MESSAGE)) }
            return
        }
        _state.update { it.copy(isPurchasing = true, state = PurchaseState.Purchasing(productID)) }
        var result: PurchaseState = PurchaseState.Idle
        try {
            result = purchaseState(gateway.launchPurchase(product), productID)
        } catch (e: CancellationException) {
            result = PurchaseState.Idle
            throw e
        } catch (_: Exception) {
            result = PurchaseState.Failed(CONFIRMATION_MESSAGE)
        } finally {
            _state.update { it.copy(isPurchasing = false, state = result) }
        }
    }

    private suspend fun purchaseState(result: FlowResult, productID: String): PurchaseState = when (result) {
        FlowResult.Cancelled -> PurchaseState.Idle
        is FlowResult.Failed -> when (result.error) {
            // An earlier tip of this product was never consumed; Play blocks the next until it is.
            BillingError.ALREADY_OWNED ->
                if (Outcome.COMPLETED in recover(productID)) PurchaseState.Thanked else PurchaseState.Failed(CONFIRMATION_MESSAGE)
            BillingError.BILLING_UNAVAILABLE -> PurchaseState.Failed(NOT_ALLOWED_MESSAGE)
            BillingError.ITEM_UNAVAILABLE -> PurchaseState.Failed(UNAVAILABLE_PRODUCT_MESSAGE)
            BillingError.NO_ACTIVITY -> PurchaseState.Failed(NO_ACTIVITY_MESSAGE)
            BillingError.NETWORK, BillingError.OTHER -> PurchaseState.Failed(CONFIRMATION_MESSAGE)
        }
        is FlowResult.Purchased -> {
            val purchase = result.purchases.firstOrNull { productID in it.products } ?: result.purchases.firstOrNull()
            if (purchase == null) {
                PurchaseState.Failed(CONFIRMATION_MESSAGE)
            } else {
                when (handle(purchase, Source.PURCHASE, expectedProductID = productID)) {
                    Outcome.COMPLETED, Outcome.DUPLICATE -> PurchaseState.Thanked
                    Outcome.PENDING -> PurchaseState.Pending
                    Outcome.UNVERIFIED -> PurchaseState.Failed(VERIFICATION_MESSAGE)
                    Outcome.UNSUPPORTED, Outcome.UNEXPECTED_PRODUCT -> PurchaseState.Failed(CONFIRMATION_MESSAGE)
                }
            }
        }
    }

    fun dismissMessage() {
        when (_state.value.state) {
            PurchaseState.Thanked, PurchaseState.Pending, is PurchaseState.Failed ->
                _state.update { it.copy(state = PurchaseState.Idle) }
            else -> Unit
        }
    }

    /** Handles every unconsumed tip Play still holds; returns the outcomes for [productID], or all. */
    suspend fun recover(productID: String? = null): List<Outcome> {
        val purchases = try {
            gateway.queryPurchases(ProductKind.ONE_TIME)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            return emptyList()
        }
        return purchases.mapNotNull { purchase ->
            val outcome = handle(purchase, Source.RECOVERY)
            outcome.takeIf { productID == null || productID in purchase.products }
        }
    }

    suspend fun handle(purchase: StorePurchase, source: Source, expectedProductID: String? = null): Outcome {
        val productID = purchase.products.singleOrNull()
        val background = source != Source.PURCHASE
        when (purchase.status) {
            PurchaseStatus.PURCHASED -> Unit
            // Play delivers the purchase again once the payment completes.
            PurchaseStatus.PENDING -> return Outcome.PENDING
            PurchaseStatus.UNSPECIFIED -> return Outcome.UNSUPPORTED
        }
        if (!verifier.verify(purchase)) {
            // Left unconsumed so a later verified delivery can still record it.
            if (background && !_state.value.isPurchasing && productID != null && SupportProducts.isTip(productID)) {
                _state.update { it.copy(state = PurchaseState.Failed(VERIFICATION_MESSAGE)) }
            }
            return Outcome.UNVERIFIED
        }
        if (productID == null || !SupportProducts.isTip(productID)) return Outcome.UNSUPPORTED
        if (expectedProductID != null && expectedProductID != productID) return Outcome.UNEXPECTED_PRODUCT

        val key = purchase.ledgerKey
        val outcome = if (recorded.add(key)) Outcome.COMPLETED else Outcome.DUPLICATE
        if (outcome == Outcome.COMPLETED) {
            _state.update { it.copy(tipCount = recorded.size) }
            // Persist before consuming: purchase, update and recovery deliveries can overlap.
            ledger.write { TipLedger(recorded.toList()) }
        }
        // A background approval must not replace another purchase's progress or result.
        if (background && !_state.value.isPurchasing && outcome == Outcome.COMPLETED) {
            _state.update { it.copy(state = PurchaseState.Thanked) }
        }
        consume(purchase.purchaseToken)
        return outcome
    }

    private suspend fun consume(token: String) {
        consumes[token]?.let { return it.await() }
        val done = CompletableDeferred<Unit>()
        consumes[token] = done
        try {
            gateway.consume(token)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            // Still owned on Play, so the next recovery redelivers it; the ledger stops a recount.
        } finally {
            consumes.remove(token)
            done.complete(Unit)
        }
    }

    companion object {
        const val UNAVAILABLE_MESSAGE = "Tips aren't available in Google Play right now. Please try again later."
        const val PARTIAL_MESSAGE = "Some tips aren't available right now. You can choose an available tip or try again."
        const val INTERRUPTED_MESSAGE = "Loading was interrupted. Please try again."
        const val LOAD_FAILED_MESSAGE = "Couldn't load tips from Google Play. Check your connection and try again."
        const val NOT_AVAILABLE_MESSAGE = "This tip is not available. Please reload the tip jar."
        const val NOT_ALLOWED_MESSAGE = "In-app purchases aren't allowed on this device."
        const val UNAVAILABLE_PRODUCT_MESSAGE = "This tip is currently unavailable in Google Play. Please try again later."
        const val NO_ACTIVITY_MESSAGE = "Google Play couldn't open the purchase. Please try again."
        const val VERIFICATION_MESSAGE =
            "The Google Play purchase could not be verified. Check your purchase history before trying again."
        const val CONFIRMATION_MESSAGE =
            "We couldn't confirm your tip. Check your Google Play purchase history before trying again."
    }
}

internal fun StoreProduct.toSupportProduct(): SupportProduct = SupportProduct(
    id = SupportProducts.contractAnnualID(id) ?: id,
    name = name,
    description = description,
    displayPrice = displayPrice,
)
