package com.agraabhi.oshodiscourses.billing

import com.agraabhi.oshodiscourses.core.domain.support.SupportStore

/**
 * Contract product IDs (the iOS IDs) and their Play Console IDs. Tips keep the iOS IDs; the
 * yearly IDs drop `com.agraabhi.` because Play caps subscription IDs at 40 characters.
 */
internal object SupportProducts {
    val tipIDs: List<String> = SupportStore.TIP_PRODUCTS.map { it.id }

    private const val ANNUAL_PREFIX_DROPPED_ON_PLAY = "com.agraabhi."

    /** Contract ID to Play subscription ID, in contract order. */
    val annualPlayIDs: Map<String, String> =
        SupportStore.ANNUAL_PRODUCT_IDS.associateWith { it.removePrefix(ANNUAL_PREFIX_DROPPED_ON_PLAY) }

    /** Each yearly subscription has one auto-renewing base plan with this ID. */
    const val ANNUAL_BASE_PLAN_ID: String = "yearly"

    const val ANNUAL_BILLING_PERIOD: String = "P1Y"

    fun isTip(productID: String, kind: ProductKind): Boolean = productID in tipIDs && kind == ProductKind.ONE_TIME

    fun isTip(productID: String): Boolean = productID in tipIDs

    fun contractAnnualID(playID: String): String? = annualPlayIDs.entries.firstOrNull { it.value == playID }?.key

    fun isAnnualPlayID(playID: String): Boolean = contractAnnualID(playID) != null

    fun isAnnualSupport(product: StoreProduct): Boolean =
        product.kind == ProductKind.SUBSCRIPTION && isAnnualPlayID(product.id) && product.billingPeriod == ANNUAL_BILLING_PERIOD
}
