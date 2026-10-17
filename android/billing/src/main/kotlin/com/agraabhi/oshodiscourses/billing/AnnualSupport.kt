package com.agraabhi.oshodiscourses.billing

import com.agraabhi.oshodiscourses.core.domain.support.AnnualSupportState
import com.agraabhi.oshodiscourses.core.domain.support.PurchaseState
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.serialization.Serializable

/**
 * The pending yearly request (iOS `annualSupport.pendingProductID`). [listedByPlay] records that a
 * status query has returned the pending purchase, so its later absence means Play cancelled it.
 */
@Serializable
internal data class AnnualRecord(
    val pendingProductID: String? = null,
    val pendingPurchaseToken: String? = null,
    val listedByPlay: Boolean = false,
)

/**
 * Yearly support (iOS `AnnualSupportService`): status comes from Play's purchase list, never a local
 * flag. Callers confine it to one thread ([PlaySupportStore]).
 */
internal class AnnualSupport(
    private val gateway: BillingGateway,
    private val verifier: PurchaseVerifier,
    private val store: JsonFileStore<AnnualRecord>,
) {
    private var record: AnnualRecord =
        store.read().takeIf { saved -> saved.pendingProductID?.let { it in SupportProducts.annualPlayIDs } == true } ?: AnnualRecord()

    private val _state = MutableStateFlow(
        AnnualSupportState(
            pendingProductID = record.pendingProductID,
            state = if (record.pendingProductID != null) PurchaseState.Pending else PurchaseState.Idle,
        ),
    )
    val state: StateFlow<AnnualSupportState> = _state

    private var storeProducts: Map<String, StoreProduct> = emptyMap()
    private val acknowledgements = mutableMapOf<String, CompletableDeferred<Unit>>()
    private var refresh: CompletableDeferred<Unit>? = null
    private var needsRefresh = false

    suspend fun loadProducts() {
        val current = _state.value
        if (current.isLoading || current.isPurchasing || current.isRestoring) return
        _state.update { it.copy(isLoading = true, loadError = null) }
        try {
            val annual = gateway.queryProducts(ProductKind.SUBSCRIPTION, SupportProducts.annualPlayIDs.values.toList())
                .filter(SupportProducts::isAnnualSupport)
                .sortedBy { it.priceMicros }
            storeProducts = annual.associateBy { SupportProducts.contractAnnualID(it.id)!! }
            val error = if (annual.size < SupportProducts.annualPlayIDs.size) PARTIAL_MESSAGE else null
            _state.update { it.copy(products = annual.map(StoreProduct::toSupportProduct), loadError = error) }
            refreshStatus()
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            storeProducts = emptyMap()
            _state.update { it.copy(products = emptyList(), statusIsCurrent = false, loadError = LOAD_FAILED_MESSAGE) }
        } finally {
            _state.update { it.copy(isLoading = false) }
        }
    }

    /** Overlapping callers wait for a snapshot taken after their request, not the one in flight. */
    suspend fun refreshStatus() {
        refresh?.let {
            needsRefresh = true
            it.await()
            return
        }
        val done = CompletableDeferred<Unit>()
        refresh = done
        _state.update { it.copy(isRefreshingStatus = true) }
        try {
            do {
                needsRefresh = false
                _state.update { it.copy(statusIsCurrent = false) }
                try {
                    applyStatus(gateway.queryPurchases(ProductKind.SUBSCRIPTION))
                } catch (e: CancellationException) {
                    throw e
                } catch (_: Exception) {
                    _state.update { it.copy(statusError = STATUS_FAILED_MESSAGE) }
                }
            } while (needsRefresh)
        } finally {
            refresh = null
            _state.update { it.copy(isRefreshingStatus = false) }
            done.complete(Unit)
        }
    }

    private suspend fun applyStatus(purchases: List<StorePurchase>) {
        if (purchases.any { !verifier.verify(it) }) throw BillingException(BillingError.OTHER, "unverified subscription")
        // Every subscription in this app counts, so a future tier also blocks a duplicate.
        val current = purchases.firstOrNull { it.status == PurchaseStatus.PURCHASED }
        val currentID = current?.products?.firstOrNull()?.let { SupportProducts.contractAnnualID(it) ?: it }
        _state.update { it.copy(currentProductID = currentID, statusError = null, statusIsCurrent = true) }

        // Play refunds a subscription that stays unacknowledged for three days.
        purchases.filter { it.status == PurchaseStatus.PURCHASED && !it.isAcknowledged && it.isAnnual }
            .forEach { acknowledge(it.purchaseToken) }

        val pending = purchases.firstOrNull { it.status == PurchaseStatus.PENDING && it.isAnnual }
        when {
            currentID != null -> clearDeclinedRequest()
            pending != null -> rememberPending(
                SupportProducts.contractAnnualID(pending.products.first())!!,
                pending.purchaseToken,
                listedByPlay = true,
            )
            record.pendingProductID != null && record.listedByPlay -> clearDeclinedRequest()
        }
        if (_state.value.state == PurchaseState.Thanked && _state.value.currentProductID == null) {
            _state.update { it.copy(state = PurchaseState.Idle) }
        }
    }

    suspend fun purchase(productID: String) {
        if (!_state.value.canPurchase) return
        val product = storeProducts[productID]?.takeIf(SupportProducts::isAnnualSupport) ?: return
        _state.update { it.copy(isPurchasing = true, restoreMessage = null, state = PurchaseState.Purchasing(productID)) }
        var result: PurchaseState = PurchaseState.Idle
        var pendingToken: String? = null
        try {
            result = when (val flow = gateway.launchPurchase(product)) {
                FlowResult.Cancelled -> PurchaseState.Idle
                is FlowResult.Failed ->
                    if (flow.error == BillingError.ALREADY_OWNED) {
                        refreshStatus()
                        PurchaseState.Idle
                    } else {
                        PurchaseState.Failed(CONFIRMATION_MESSAGE)
                    }
                is FlowResult.Purchased -> {
                    val purchase = flow.purchases.firstOrNull { product.id in it.products } ?: flow.purchases.firstOrNull()
                    when (purchase?.status) {
                        PurchaseStatus.PENDING -> {
                            pendingToken = purchase.purchaseToken
                            PurchaseState.Pending
                        }
                        PurchaseStatus.PURCHASED -> purchaseState(purchase, productID)
                        PurchaseStatus.UNSPECIFIED, null -> PurchaseState.Failed(CONFIRMATION_MESSAGE)
                    }
                }
            }
        } catch (e: CancellationException) {
            result = PurchaseState.Idle
            throw e
        } catch (_: Exception) {
            result = PurchaseState.Failed(CONFIRMATION_MESSAGE)
        } finally {
            if (result == PurchaseState.Pending && _state.value.currentProductID != null) result = PurchaseState.Idle
            _state.update { it.copy(isPurchasing = false, state = result) }
        }
        if (result == PurchaseState.Pending) rememberPending(productID, pendingToken, listedByPlay = false)
    }

    /** The purchase sheet's result; thanks only once Play lists the subscription as current. */
    suspend fun purchaseState(purchase: StorePurchase, productID: String): PurchaseState {
        val confirmed = finish(purchase, expectedProductID = productID)
        refreshStatus()
        val state = _state.value
        return if (confirmed && state.statusIsCurrent && state.currentProductID != null) {
            PurchaseState.Thanked
        } else {
            PurchaseState.Failed(VERIFICATION_FAILED_MESSAGE)
        }
    }

    /** Renewals, approvals and promo-code redemptions: refresh quietly, never thank. */
    suspend fun handleUpdate(purchase: StorePurchase) {
        if (!purchase.isAnnual) return
        finish(purchase)
        refreshStatus()
    }

    /** Acknowledges a verified, completed yearly purchase; false for anything that must not be thanked. */
    suspend fun finish(purchase: StorePurchase, expectedProductID: String? = null): Boolean {
        val playID = purchase.products.singleOrNull()
        val contractID = playID?.let(SupportProducts::contractAnnualID)
        if (purchase.status != PurchaseStatus.PURCHASED || !verifier.verify(purchase) || contractID == null ||
            (expectedProductID != null && expectedProductID != contractID)
        ) {
            return false
        }
        if (!purchase.isAcknowledged) acknowledge(purchase.purchaseToken)
        return true
    }

    private suspend fun acknowledge(token: String) {
        acknowledgements[token]?.let { return it.await() }
        val done = CompletableDeferred<Unit>()
        acknowledgements[token] = done
        try {
            gateway.acknowledge(token)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            // The next status refresh retries while Play still lists it unacknowledged.
        } finally {
            acknowledgements.remove(token)
            done.complete(Unit)
        }
    }

    /** Play has no account sync to trigger; restoring re-reads the account's current subscriptions. */
    suspend fun restore() {
        val current = _state.value
        if (current.isBusy || current.state != PurchaseState.Idle) return
        _state.update { it.copy(isRestoring = true, restoreMessage = null) }
        try {
            refreshStatus()
            val state = _state.value
            _state.update {
                if (state.statusIsCurrent) {
                    it.copy(restoreMessage = if (state.currentProductID == null) RESTORE_NONE_MESSAGE else RESTORE_FOUND_MESSAGE)
                } else {
                    it.copy(state = PurchaseState.Failed(RESTORE_FAILED_MESSAGE))
                }
            }
        } finally {
            _state.update { it.copy(isRestoring = false) }
        }
    }

    fun dismissMessage() {
        when (_state.value.state) {
            PurchaseState.Thanked, PurchaseState.Pending, is PurchaseState.Failed ->
                _state.update { it.copy(state = PurchaseState.Idle) }
            else -> Unit
        }
    }

    /** Forgets a pending request the listener says was declined or cancelled. */
    suspend fun clearDeclinedRequest() {
        val hadMarker = record.pendingProductID != null
        record = AnnualRecord()
        _state.update {
            it.copy(pendingProductID = null, state = if (it.state == PurchaseState.Pending) PurchaseState.Idle else it.state)
        }
        if (hadMarker) store.write { record }
    }

    private suspend fun rememberPending(productID: String, token: String?, listedByPlay: Boolean) {
        val next = AnnualRecord(productID, token ?: record.pendingPurchaseToken, listedByPlay || record.listedByPlay)
        if (next == record) return
        record = next
        _state.update { it.copy(pendingProductID = productID) }
        store.write { record }
    }

    private val StorePurchase.isAnnual: Boolean get() = products.any(SupportProducts::isAnnualPlayID)

    companion object {
        const val PARTIAL_MESSAGE = "Some yearly support options aren't available right now. Please try again later."
        const val LOAD_FAILED_MESSAGE =
            "Couldn't load yearly support from Google Play. Check your connection and try again."
        const val STATUS_FAILED_MESSAGE =
            "Couldn't check your existing yearly support. Try again before starting a subscription."
        const val CONFIRMATION_MESSAGE =
            "Couldn't confirm your subscription. Check your Google Play subscriptions before trying again."
        const val VERIFICATION_FAILED_MESSAGE =
            "Couldn't verify your subscription. Check your Google Play subscriptions before trying again."
        const val RESTORE_NONE_MESSAGE = "No current yearly support subscription was found."
        const val RESTORE_FOUND_MESSAGE = "Your yearly support subscription is restored. Thank you."
        const val RESTORE_FAILED_MESSAGE = "Couldn't restore your subscription. Please try again later."
    }
}
