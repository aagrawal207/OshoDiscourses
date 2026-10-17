package com.agraabhi.oshodiscourses.billing

import android.app.Activity
import android.content.Context
import com.agraabhi.oshodiscourses.core.domain.support.AnnualSupportState
import com.agraabhi.oshodiscourses.core.domain.support.SupportStore
import com.agraabhi.oshodiscourses.core.domain.support.TipJarState
import java.io.File
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * [SupportStore] over Google Play Billing. Every call runs on [dispatcher], one thread, so the
 * busy checks hold across suspension the way iOS's `@MainActor` services do.
 */
class PlaySupportStore internal constructor(
    private val gateway: BillingGateway,
    verifier: PurchaseVerifier,
    filesDir: File,
    scope: CoroutineScope,
    private val dispatcher: CoroutineDispatcher,
    io: CoroutineDispatcher = Dispatchers.IO,
) : SupportStore {
    /**
     * [licenseKey] is the Base64 RSA key from Play Console > Monetization setup. Without it,
     * purchase signatures are not checked; release builds must supply it.
     */
    constructor(
        context: Context,
        activityProvider: () -> Activity?,
        scope: CoroutineScope,
        licenseKey: String? = null,
    ) : this(
        gateway = PlayBillingGateway(context, activityProvider),
        verifier = PurchaseVerifier.forLicenseKey(licenseKey),
        filesDir = context.filesDir,
        scope = scope,
        dispatcher = Dispatchers.Main.immediate,
    )

    private val tips = TipJar(gateway, verifier, JsonFileStore(File(filesDir, TIP_JAR_FILE), TipLedger.serializer(), TipLedger(), io))
    private val annual = AnnualSupport(
        gateway,
        verifier,
        JsonFileStore(File(filesDir, ANNUAL_SUPPORT_FILE), AnnualRecord.serializer(), AnnualRecord(), io),
    )

    override val tipJar: StateFlow<TipJarState> = tips.state
    override val annualSupport: StateFlow<AnnualSupportState> = annual.state

    init {
        scope.launch(dispatcher) {
            gateway.updates.collect { purchases -> purchases.forEach { route(it) } }
        }
        scope.launch(dispatcher) { recoverPurchases() }
    }

    private suspend fun route(purchase: StorePurchase) {
        when {
            purchase.products.any(SupportProducts::isTip) -> tips.handle(purchase, TipJar.Source.UPDATE)
            purchase.products.any(SupportProducts::isAnnualPlayID) -> annual.handleUpdate(purchase)
        }
    }

    /**
     * Records tips approved while the app was closed and re-reads subscription status. Play has
     * no renewal stream, so `:app` should call this when the app returns to the foreground.
     */
    suspend fun recoverPurchases() = withContext(dispatcher) {
        tips.recover()
        annual.refreshStatus()
    }

    override suspend fun loadTipProducts() = withContext(dispatcher) {
        tips.loadProducts()
        tips.recover()
        Unit
    }

    override suspend fun purchaseTip(productID: String) = withContext(dispatcher) { tips.purchase(productID) }

    override suspend fun dismissTipMessage() = withContext(dispatcher) { tips.dismissMessage() }

    override suspend fun loadAnnualProducts() = withContext(dispatcher) { annual.loadProducts() }

    override suspend fun refreshAnnualStatus() = withContext(dispatcher) { annual.refreshStatus() }

    override suspend fun purchaseAnnual(productID: String) = withContext(dispatcher) { annual.purchase(productID) }

    override suspend fun restore() = withContext(dispatcher) {
        tips.recover()
        annual.restore()
    }

    override suspend fun dismissAnnualMessage() = withContext(dispatcher) { annual.dismissMessage() }

    /** iOS's explicit clear for a request the listener says was declined; not yet in [SupportStore]. */
    suspend fun clearDeclinedAnnualRequest() = withContext(dispatcher) { annual.clearDeclinedRequest() }

    internal companion object {
        const val TIP_JAR_FILE = "tip_jar.json"
        const val ANNUAL_SUPPORT_FILE = "annual_support.json"
    }
}
