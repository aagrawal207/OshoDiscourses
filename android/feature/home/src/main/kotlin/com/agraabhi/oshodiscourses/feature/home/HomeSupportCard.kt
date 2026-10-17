package com.agraabhi.oshodiscourses.feature.home

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.compose.currentStateAsState
import com.agraabhi.oshodiscourses.core.domain.AppServices
import com.agraabhi.oshodiscourses.core.domain.engagement.EngagementService
import com.agraabhi.oshodiscourses.core.domain.engagement.SubscriptionStatus
import com.agraabhi.oshodiscourses.core.domain.engagement.SupportContext
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import kotlinx.coroutines.launch
import java.util.UUID

/** iOS `EngagementService.hasEstablishedUse`: seven listening days and two hours in total. */
internal fun hasEstablishedUse(context: SupportContext): Boolean =
    context.activeDays >= EngagementService.SUPPORT_ACTIVE_DAYS_THRESHOLD &&
        context.totalListening >= EngagementService.SUPPORT_LISTENING_THRESHOLD_SECONDS

/** One Home support-card presentation (iOS `HomeSupportPresentation`). */
@Stable
internal class HomeSupportState(private val engagement: EngagementService) {
    val owner: String = UUID.randomUUID().toString()
    var context by mutableStateOf(SupportContext())
        private set
    var showsCard by mutableStateOf(false)
        private set
    var showsSheet by mutableStateOf(false)
        private set

    fun update(context: SupportContext) {
        this.context = context
        val began = engagement.beginSupportPresentation(owner, context)
        if (!began) engagement.endSupportPresentation(owner)
        showsCard = began && engagement.canShowSupportCard(owner, context)
    }

    suspend fun openSupport(present: (onDismissed: () -> Unit) -> Unit) {
        if (!engagement.openSupportSheet(owner, context)) return
        showsSheet = true
        showsCard = false
        present {
            showsSheet = false
            engagement.endSupportSheet(owner)
        }
    }

    suspend fun dismiss(permanently: Boolean) {
        engagement.dismissSupport(owner, context, permanently)
        showsCard = false
    }

    suspend fun recordExposure() {
        engagement.recordSupportExposure(owner, context)
    }

    fun leaveHome() {
        showsCard = false
        engagement.endSupportPresentation(owner)
    }
}

/** Builds the quiet-moment context and keeps the presentation in step (iOS `HomeSupportObserver`). */
@Composable
internal fun rememberHomeSupportState(
    services: AppServices,
    enabled: Boolean,
    isPlayerPresented: Boolean,
    isOtherSheetPresented: Boolean,
): HomeSupportState {
    val state = remember(services.engagement) { HomeSupportState(services.engagement) }
    if (!enabled) return state

    val stats by services.listeningStats.stats.collectAsStateWithLifecycle()
    val tips by services.support.tipJar.collectAsStateWithLifecycle()
    val annual by services.support.annualSupport.collectAsStateWithLifecycle()
    val player by services.player.state.collectAsStateWithLifecycle()
    val sleep by services.sleepTimer.state.collectAsStateWithLifecycle()
    val lifecycle by LocalLifecycleOwner.current.lifecycle.currentStateAsState()

    var context = SupportContext(
        activeDays = stats.distinctActiveDays,
        totalListening = stats.totalAllTime,
        tipCount = tips.tipCount,
        isForeground = lifecycle.isAtLeast(Lifecycle.State.RESUMED),
        // Home is composed only while it is the top of the selected tab's stack.
        isHomeVisible = true,
        isPlaying = player.isPlaying,
        sleepTimerArmed = sleep.isActive,
        playerPresented = isPlayerPresented,
        otherPresentationActive = state.showsSheet || isOtherSheetPresented,
        storeIsBusy = tips.isLoading || tips.isPurchasing,
    )
    if (hasEstablishedUse(context) && context.tipCount == 0) {
        val status = when {
            annual.currentProductID != null -> SubscriptionStatus.SUBSCRIBED
            annual.statusIsCurrent -> SubscriptionStatus.NOT_SUBSCRIBED
            else -> SubscriptionStatus.UNKNOWN
        }
        context = context.copy(subscriptionStatus = status, storeIsBusy = context.storeIsBusy || annual.isBusy)
    }
    // Status loading changes these fields itself; they must not restart a failed lookup.
    val statusCheckOpportunity = context.copy(subscriptionStatus = SubscriptionStatus.UNKNOWN, storeIsBusy = false)

    LaunchedEffect(context) { state.update(context) }
    LaunchedEffect(statusCheckOpportunity) {
        state.update(context)
        services.engagement.refreshSupportStatusIfNeeded(context) { services.support.refreshAnnualStatus() }
    }
    DisposableEffect(state) { onDispose { state.leaveHome() } }
    return state
}

/** The inline Home ask (iOS `HomeSupportCard`). Buttons sit in one row, or a column when they do not fit. */
@Composable
internal fun HomeSupportCard(
    state: HomeSupportState,
    onOpenSupport: (onDismissed: () -> Unit) -> Unit,
    modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()
    LaunchedEffect(state.owner) { state.recordExposure() }
    Column(
        modifier = modifier
            .padding(horizontal = 16.dp)
            .widthIn(max = 640.dp)
            .fillMaxWidth()
            .background(Osho.colors.secondarySystemGroupedBackground, RoundedCornerShape(16.dp))
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text("Optional support helps me keep improving Osho Talks.", style = Osho.typography.subheadline, color = Osho.colors.label)
        RowOrColumn {
            SupportButton("Support", bold = true) { scope.launch { state.openSupport(onOpenSupport) } }
            SupportButton("Not Now") { scope.launch { state.dismiss(permanently = false) } }
            SupportButton("Don't Ask Again") { scope.launch { state.dismiss(permanently = true) } }
        }
    }
}

@Composable
private fun SupportButton(label: String, bold: Boolean = false, onClick: () -> Unit) {
    Box(
        modifier = Modifier.sizeIn(minWidth = 44.dp, minHeight = 44.dp).clickable(role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.CenterStart,
    ) {
        Text(
            label,
            style = Osho.typography.subheadline,
            fontWeight = if (bold) FontWeight.SemiBold else FontWeight.Normal,
            color = Osho.colors.accent,
        )
    }
}

/** SwiftUI `ViewThatFits`: a 12 dp-spaced row when it fits the width, else a leading column. */
@Composable
private fun RowOrColumn(content: @Composable () -> Unit) {
    Layout(content) { measurables, constraints ->
        val loose = constraints.copy(minWidth = 0, minHeight = 0)
        val placeables = measurables.map { it.measure(loose) }
        val gap = 12.dp.roundToPx()
        val rowWidth = placeables.sumOf { it.width } + gap * (placeables.size - 1).coerceAtLeast(0)
        if (rowWidth <= constraints.maxWidth) {
            val height = placeables.maxOf { it.height }
            layout(rowWidth, height) {
                var x = 0
                placeables.forEach {
                    it.placeRelative(x, (height - it.height) / 2)
                    x += it.width + gap
                }
            }
        } else {
            layout(placeables.maxOf { it.width }, placeables.sumOf { it.height }) {
                var y = 0
                placeables.forEach {
                    it.placeRelative(0, y)
                    y += it.height
                }
            }
        }
    }
}
