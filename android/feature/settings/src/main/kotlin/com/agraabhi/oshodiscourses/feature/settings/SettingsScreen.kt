package com.agraabhi.oshodiscourses.feature.settings

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation3.runtime.NavKey
import com.agraabhi.oshodiscourses.core.ui.LocalAppServices
import com.agraabhi.oshodiscourses.core.ui.LocalMiniPlayerClearance
import com.agraabhi.oshodiscourses.core.ui.LocalTabBarClearance
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import com.agraabhi.oshodiscourses.core.ui.theme.ProvideElevatedSurfaces
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable

/** The Settings tab's root. */
@Serializable
data object SettingsRoute : NavKey

internal const val SOURCE_CODE_URL = "https://github.com/aagrawal207/OshoDiscourses"
internal const val FEEDBACK_MAILTO = "mailto:aagrawal207@gmail.com?subject=Osho%20Talks%20Feedback"

/**
 * Language, player and download prefs, DeNoise, appearance, Google Drive sync and About
 * (iOS `SettingsView`). Support Development opens [SupportDevelopmentSheet] here unless
 * [onOpenSupport] hands it to the app. [versionName] defaults to the installed package's.
 */
@Composable
fun SettingsScreen(
    onOpenDenoise: () -> Unit,
    @Suppress("UNUSED_PARAMETER") onOpenListeningStats: () -> Unit,
    modifier: Modifier = Modifier,
    versionName: String? = null,
    onOpenSupport: (() -> Unit)? = null,
) {
    val services = LocalAppServices.current
    val context = LocalContext.current
    val vm = viewModel { SettingsViewModel(services.settings, services.sync, services.catalog) }
    val state by vm.state.collectAsStateWithLifecycle()
    var showSupport by rememberSaveable { mutableStateOf(false) }
    val version = remember(versionName) { versionName ?: context.installedVersionName() }
    SettingsContent(
        state = state,
        versionName = version,
        modifier = modifier,
        actions = SettingsActions(
            onLanguage = { vm.setLanguage(it) },
            onAutoPlayNext = { vm.setAutoPlayNext(it) },
            onSmartDownload = { vm.setSmartDownload(it) },
            onSmartDelete = { vm.setSmartDelete(it) },
            onAllowCellular = { vm.setAllowCellular(it) },
            onOpenDenoise = onOpenDenoise,
            onAppearance = { vm.setAppearance(it) },
            onPickAccent = { vm.pickAccent(it) },
            onShuffle = { vm.setShuffle(it) },
            onSignIn = { vm.signIn() },
            onSyncNow = { vm.syncNow() },
            onSignOut = { vm.signOut() },
            onOpenSupport = onOpenSupport ?: { showSupport = true },
            onRate = { context.openUrl(services.reviewPrompter.writeReviewURL) },
            onSourceCode = { context.openUrl(SOURCE_CODE_URL) },
            onFeedback = { context.sendFeedback() },
        ),
    )
    if (showSupport) SupportDevelopmentSheet(onDismiss = { showSupport = false })
}

/**
 * The Support Development sheet (iOS `TipJarView`): tips and yearly support from `SupportStore`.
 * Also opened by the Home support card. [onClearDeclinedRequest] shows "Request Was Declined".
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SupportDevelopmentSheet(onDismiss: () -> Unit, onClearDeclinedRequest: (() -> Unit)? = null) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    val hide: () -> Unit = { scope.launch { sheetState.hide() }.invokeOnCompletion { onDismiss() } }
    ProvideElevatedSurfaces {
        ModalBottomSheet(
            onDismissRequest = onDismiss,
            sheetState = sheetState,
            dragHandle = null,
            containerColor = Osho.colors.systemGroupedBackground,
            scrimColor = Color.Black.copy(alpha = 0.4f),
            shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp),
            // The page pads for the status bar itself, as it does full screen.
            contentWindowInsets = { WindowInsets(0) },
        ) {
            CompositionLocalProvider(LocalTabBarClearance provides 0.dp, LocalMiniPlayerClearance provides 0.dp) {
                SupportDevelopmentPage(onDone = hide, onClearDeclinedRequest = onClearDeclinedRequest)
            }
        }
    }
}

/** The sheet's content without the sheet, for a full-screen destination or tests. */
@Composable
fun SupportDevelopmentPage(onDone: () -> Unit, modifier: Modifier = Modifier, onClearDeclinedRequest: (() -> Unit)? = null) {
    val services = LocalAppServices.current
    val context = LocalContext.current
    val vm = viewModel(key = "supportDevelopment") { TipJarViewModel(services.support, services.engagement) }
    val state by vm.state.collectAsStateWithLifecycle()
    LaunchedEffect(Unit) { vm.load() }
    DisposableEffect(Unit) {
        vm.onShown()
        onDispose { vm.onHidden() }
    }
    // Returning from Play (manage subscriptions, a pending approval) may change the plan.
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { vm.refreshStatus() }
    TipJarContent(
        state = state,
        modifier = modifier,
        actions = TipJarActions(
            onDone = onDone,
            onPurchase = { vm.purchase(it) },
            onRetryTips = { vm.loadTips() },
            onRetryAnnual = { vm.loadAnnual() },
            onRefreshStatus = { vm.refreshStatus() },
            onRestore = { vm.restore() },
            onManageSubscriptions = { context.openUrl(manageSubscriptionsUrl(context.packageName, state.annual.currentProductID)) },
            onOpenUrl = { context.openUrl(it) },
            onDismissMessages = { vm.dismissMessages() },
            onClearDeclinedRequest = onClearDeclinedRequest,
        ),
    )
}

/** Play's subscription centre, deep-linked to the current plan when there is one. */
internal fun manageSubscriptionsUrl(packageName: String, productID: String?): String {
    val base = "https://play.google.com/store/account/subscriptions?package=$packageName"
    return if (productID == null) base else "$base&sku=$productID"
}

private fun Context.openUrl(url: String) {
    try {
        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    } catch (_: ActivityNotFoundException) {
        // No browser or store app; iOS Link fails silently in the same case.
    }
}

private fun Context.sendFeedback() {
    try {
        startActivity(Intent(Intent.ACTION_SENDTO, Uri.parse(FEEDBACK_MAILTO)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    } catch (_: ActivityNotFoundException) {
        openUrl(FEEDBACK_MAILTO)
    }
}

private fun Context.installedVersionName(): String = try {
    val info = if (Build.VERSION.SDK_INT >= 33) {
        packageManager.getPackageInfo(packageName, android.content.pm.PackageManager.PackageInfoFlags.of(0))
    } else {
        @Suppress("DEPRECATION")
        packageManager.getPackageInfo(packageName, 0)
    }
    info.versionName ?: "—"
} catch (_: Exception) {
    "—"
}
