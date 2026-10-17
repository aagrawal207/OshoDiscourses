package com.agraabhi.oshodiscourses.core.testing

import com.agraabhi.oshodiscourses.core.domain.engagement.EngagementHistory
import com.agraabhi.oshodiscourses.core.domain.engagement.EngagementService
import com.agraabhi.oshodiscourses.core.domain.engagement.ReviewPrompter
import com.agraabhi.oshodiscourses.core.domain.engagement.SupportContext
import com.agraabhi.oshodiscourses.core.domain.support.AnnualSupportState
import com.agraabhi.oshodiscourses.core.domain.support.PurchaseState
import com.agraabhi.oshodiscourses.core.domain.support.SupportProduct
import com.agraabhi.oshodiscourses.core.domain.support.SupportStore
import com.agraabhi.oshodiscourses.core.domain.support.TipJarState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update

object SampleSupportProducts {
    val tips: List<SupportProduct> = SupportStore.TIP_PRODUCTS.map {
        SupportProduct(it.id, it.name, "A one-time tip. It unlocks nothing.", it.basePrice.removePrefix("US"))
    }

    val annual: List<SupportProduct> = listOf(
        SupportProduct(SupportStore.ANNUAL_PRODUCT_IDS[0], "Yearly support", "Renews yearly.", "$5.00"),
        SupportProduct(SupportStore.ANNUAL_PRODUCT_IDS[1], "Yearly support", "Renews yearly.", "$10.00"),
        SupportProduct(SupportStore.ANNUAL_PRODUCT_IDS[2], "Yearly support", "Renews yearly.", "$15.00"),
    )
}

/** Every purchase succeeds unless [nextPurchaseResult] says otherwise. */
class FakeSupportStore(
    var nextPurchaseResult: PurchaseState = PurchaseState.Thanked,
) : SupportStore {
    override val tipJar = MutableStateFlow(TipJarState())
    override val annualSupport = MutableStateFlow(AnnualSupportState())

    override suspend fun loadTipProducts() = tipJar.update { it.copy(products = SampleSupportProducts.tips, loadError = null) }

    override suspend fun purchaseTip(productID: String) = tipJar.update {
        val result = nextPurchaseResult
        it.copy(state = result, tipCount = if (result == PurchaseState.Thanked) it.tipCount + 1 else it.tipCount)
    }

    override suspend fun dismissTipMessage() = tipJar.update { it.copy(state = PurchaseState.Idle) }

    override suspend fun loadAnnualProducts() = annualSupport.update { it.copy(products = SampleSupportProducts.annual, loadError = null) }

    override suspend fun refreshAnnualStatus() = annualSupport.update { it.copy(statusIsCurrent = true) }

    override suspend fun purchaseAnnual(productID: String) = annualSupport.update {
        val result = nextPurchaseResult
        it.copy(state = result, currentProductID = if (result == PurchaseState.Thanked) productID else it.currentProductID)
    }

    override suspend fun restore() = annualSupport.update { it.copy(statusIsCurrent = true) }

    override suspend fun dismissAnnualMessage() = annualSupport.update { it.copy(state = PurchaseState.Idle) }

    var clearedDeclinedRequests: Int = 0
        private set

    override suspend fun clearDeclinedRequest() {
        clearedDeclinedRequests++
        annualSupport.update { it.copy(pendingProductID = null, state = PurchaseState.Idle) }
    }
}

/** Allows a support card whenever [allowSupport] is true; records what the UI asked. */
class FakeEngagementService(
    var allowSupport: Boolean = false,
    var allowRating: Boolean = true,
) : EngagementService {
    override val history = MutableStateFlow(EngagementHistory())
    private val active = MutableStateFlow(false)
    override val isSupportPresentationActive: StateFlow<Boolean> = active
    private var cardOwner: String? = null
    private val sheets = mutableSetOf<String>()

    private fun refreshActive() {
        active.value = cardOwner != null || sheets.isNotEmpty()
    }

    override fun canShowSupportCard(owner: String, context: SupportContext): Boolean =
        allowSupport && (cardOwner == null || cardOwner == owner) && sheets.isEmpty()

    override fun beginSupportPresentation(owner: String, context: SupportContext): Boolean {
        if (!canShowSupportCard(owner, context)) return false
        cardOwner = owner
        refreshActive()
        return true
    }

    override suspend fun recordSupportExposure(owner: String, context: SupportContext): Boolean = cardOwner == owner

    override fun endSupportPresentation(owner: String) {
        if (cardOwner == owner) cardOwner = null
        refreshActive()
    }

    override suspend fun dismissSupport(owner: String, context: SupportContext, permanently: Boolean) {
        history.update { if (permanently) it.copy(supportOptedOut = true) else it.copy(supportSnoozedAt = 0) }
        endSupportPresentation(owner)
    }

    override suspend fun openSupportSheet(owner: String, context: SupportContext): Boolean {
        if (cardOwner != owner) return false
        endSupportPresentation(owner)
        sheets += owner
        refreshActive()
        return true
    }

    override fun endSupportSheet(owner: String) {
        sheets -= owner
        refreshActive()
    }

    override fun registerSupportSheet(owner: String) {
        sheets += owner
        refreshActive()
    }

    override fun unregisterSupportSheet(owner: String) = endSupportSheet(owner)

    override suspend fun recordRatingAttemptIfAllowed(): Boolean = allowRating && !active.value

    override suspend fun refreshSupportStatusIfNeeded(context: SupportContext, refresh: suspend () -> Unit) = refresh()
}

class FakeReviewPrompter : ReviewPrompter {
    var requests: Int = 0
        private set

    override suspend fun listenerDidPause() {
        requests++
    }

    override suspend fun discourseDidFinish(naturally: Boolean, playbackContinues: Boolean, sleepTimerWasArmed: Boolean) {
        if (naturally && !playbackContinues && !sleepTimerWasArmed) requests++
    }

    override val writeReviewURL: String = "https://play.google.com/store/apps/details?id=com.agraabhi.oshodiscourses&showAllReviews=true"
}
