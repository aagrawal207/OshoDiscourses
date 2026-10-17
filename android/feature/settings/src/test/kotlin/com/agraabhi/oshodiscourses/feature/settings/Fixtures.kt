package com.agraabhi.oshodiscourses.feature.settings

import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.junit4.ComposeContentTestRule
import androidx.compose.ui.unit.Density
import com.agraabhi.oshodiscourses.core.domain.AppServices
import com.agraabhi.oshodiscourses.core.domain.support.AnnualSupportState
import com.agraabhi.oshodiscourses.core.domain.support.PurchaseState
import com.agraabhi.oshodiscourses.core.domain.support.SupportProduct
import com.agraabhi.oshodiscourses.core.domain.support.SupportStore
import com.agraabhi.oshodiscourses.core.domain.support.TipJarState
import com.agraabhi.oshodiscourses.core.model.Appearance
import com.agraabhi.oshodiscourses.core.testing.FakeAppServices
import com.agraabhi.oshodiscourses.core.ui.LocalAppServices
import com.agraabhi.oshodiscourses.core.ui.theme.OshoTheme
import com.agraabhi.oshodiscourses.core.ui.theme.ProvideElevatedSurfaces
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update

private const val ID = "com.agraabhi.oshodiscourses."

/** The App Store products from `TipJar.storekit`, with US storefront prices. */
internal object IosProducts {
    val tips = listOf(
        SupportProduct("${ID}tip.small", "Small tip", "A coffee for the developer.", "$2.99"),
        SupportProduct("${ID}tip.medium", "Generous tip", "Covers a month of the odd fix.", "$4.99"),
        SupportProduct("${ID}tip.large", "Big tip", "Funds an afternoon on a new feature.", "$9.99"),
        SupportProduct("${ID}tip.grand", "Grand tip", "You are keeping this app alive.", "$24.99"),
        SupportProduct("${ID}tip.patron", "Patron tip", "Helps fund more improvements to the app.", "$49.99"),
    )
    val annual = listOf(
        SupportProduct("${ID}support.annual15", "Extra yearly support", "Optional support for ongoing app development.", "$14.99"),
        SupportProduct("${ID}support.annual5", "Small yearly support", "Optional support for ongoing app development.", "$4.99"),
        SupportProduct("${ID}support.annual10", "Generous yearly support", "Optional support for ongoing app development.", "$9.99"),
    )
}

/**
 * A scriptable store: loads return the iOS products unless told to fail or hang, and purchases
 * end in [nextResult]. Every call is recorded.
 */
internal class ScriptedSupportStore(
    var loadsHang: Boolean = false,
    var tipsError: String? = null,
    var annualError: String? = null,
    var nextResult: PurchaseState = PurchaseState.Thanked,
) : SupportStore {
    override val tipJar = MutableStateFlow(TipJarState())
    override val annualSupport = MutableStateFlow(AnnualSupportState())
    val calls = mutableListOf<String>()

    override suspend fun loadTipProducts() {
        calls += "loadTips"
        if (loadsHang) return tipJar.update { it.copy(isLoading = true) }
        tipJar.update { it.copy(products = if (tipsError == null) IosProducts.tips else emptyList(), loadError = tipsError, isLoading = false) }
    }

    override suspend fun purchaseTip(productID: String) {
        calls += "purchaseTip:$productID"
        tipJar.update { it.copy(state = nextResult, tipCount = if (nextResult == PurchaseState.Thanked) it.tipCount + 1 else it.tipCount) }
    }

    override suspend fun dismissTipMessage() = tipJar.update { it.copy(state = PurchaseState.Idle) }

    override suspend fun loadAnnualProducts() {
        calls += "loadAnnual"
        if (loadsHang) return annualSupport.update { it.copy(isLoading = true) }
        annualSupport.update { it.copy(products = if (annualError == null) IosProducts.annual else emptyList(), loadError = annualError, isLoading = false) }
    }

    override suspend fun refreshAnnualStatus() {
        calls += "refresh"
        if (!loadsHang) annualSupport.update { it.copy(statusIsCurrent = true) }
    }

    override suspend fun purchaseAnnual(productID: String) {
        calls += "purchaseAnnual:$productID"
        annualSupport.update {
            it.copy(
                state = nextResult,
                currentProductID = if (nextResult == PurchaseState.Thanked) productID else it.currentProductID,
                pendingProductID = if (nextResult == PurchaseState.Pending) productID else it.pendingProductID,
            )
        }
    }

    override suspend fun restore() {
        calls += "restore"
        annualSupport.update { it.copy(restoreMessage = "No current yearly support subscription was found.", statusIsCurrent = true) }
    }

    override suspend fun dismissAnnualMessage() = annualSupport.update { it.copy(state = PurchaseState.Idle) }
}

internal fun ComposeContentTestRule.show(
    services: AppServices,
    appearance: Appearance = Appearance.LIGHT,
    fontScale: Float = 1f,
    elevated: Boolean = false,
    content: @Composable () -> Unit,
) {
    setContent {
        CompositionLocalProvider(LocalAppServices provides services) {
            OshoTheme(appearance = appearance, accent = services.settings.settings.value.effectiveAccentTheme) {
                val density = LocalDensity.current
                CompositionLocalProvider(LocalDensity provides Density(density.density, fontScale)) {
                    if (elevated) ProvideElevatedSurfaces(content) else content()
                }
            }
        }
    }
}

/** Fake services with the scripted store in place of the default support fake. */
internal class ScriptedServices(
    val store: ScriptedSupportStore = ScriptedSupportStore(),
    val base: FakeAppServices = FakeAppServices(),
) : AppServices by base {
    override val support: SupportStore get() = store
}
