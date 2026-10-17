package com.agraabhi.oshodiscourses.feature.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.FavoriteBorder
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.rounded.Coffee
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.ripple
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.agraabhi.oshodiscourses.core.ui.components.ActionSheet
import com.agraabhi.oshodiscourses.core.ui.components.CardRow
import com.agraabhi.oshodiscourses.core.ui.components.GlassMaterial
import com.agraabhi.oshodiscourses.core.ui.components.GlassTextButton
import com.agraabhi.oshodiscourses.core.ui.components.GroupedPage
import com.agraabhi.oshodiscourses.core.ui.components.SheetAction
import com.agraabhi.oshodiscourses.core.ui.components.SmallSpinner
import com.agraabhi.oshodiscourses.core.ui.components.glass
import com.agraabhi.oshodiscourses.core.ui.components.isAccessibilityTextSize
import com.agraabhi.oshodiscourses.core.ui.components.rowContentPadding
import com.agraabhi.oshodiscourses.core.ui.components.sectionFooter
import com.agraabhi.oshodiscourses.core.ui.components.sectionGap
import com.agraabhi.oshodiscourses.core.ui.components.sectionHeader
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import com.agraabhi.oshodiscourses.core.ui.theme.monospacedDigits
import com.agraabhi.oshodiscourses.feature.settings.ui.IosAlert

internal const val PRIVACY_POLICY_URL = "https://github.com/aagrawal207/OshoDiscourses/blob/main/PRIVACY.md"

/** iOS links Apple's standard EULA; Play purchases fall under the Google Play Terms of Service. */
internal const val TERMS_OF_USE_URL = "https://play.google.com/about/play-terms/"

internal class TipJarActions(
    val onDone: () -> Unit = {},
    val onPurchase: (SupportRow) -> Unit = {},
    val onRetryTips: () -> Unit = {},
    val onRetryAnnual: () -> Unit = {},
    val onRefreshStatus: () -> Unit = {},
    val onRestore: () -> Unit = {},
    val onManageSubscriptions: () -> Unit = {},
    val onOpenUrl: (String) -> Unit = {},
    val onDismissMessages: () -> Unit = {},
    /** Null hides "Request Was Declined", for stores that cannot forget a declined request. */
    val onClearDeclinedRequest: (() -> Unit)? = null,
)

@Composable
internal fun TipJarContent(state: TipJarUiState, actions: TipJarActions, modifier: Modifier = Modifier, topInset: Dp? = null) {
    var confirmDeclined by remember { mutableStateOf(false) }
    GroupedPage(
        title = "Support Development",
        largeTitle = false,
        background = Osho.colors.systemGroupedBackground,
        modifier = modifier,
        navigation = { GlassTextButton("Done", actions.onDone, hazeState = null) },
        extraBottomPadding = if (state.isPending) 160.dp else 0.dp,
        topInset = topInset ?: WindowInsets.statusBars.asPaddingValues().calculateTopPadding(),
        overlay = {
            if (state.isPending) PendingBar(actions.onDismissMessages, Modifier.align(Alignment.BottomCenter))
        },
    ) {
        sectionGap("top", 16.dp)
        item(key = "intro") { CardRow(isFirst = true, isLast = true) { Intro() } }
        sectionGap("products.gap", 32.dp)
        productsSection(state, actions)
        yearlySection(state, actions, onDeclined = { confirmDeclined = true })
    }

    state.message?.let { IosAlert(it.title, it.body, actions.onDismissMessages) }

    val clear = actions.onClearDeclinedRequest
    if (confirmDeclined && clear != null) {
        ActionSheet(
            title = "Clear the pending request?",
            message = "Only clear this if the Google Play request was declined or cancelled. A request that is still pending may be approved and charged later.",
            actions = listOf(SheetAction("Clear Declined Request", destructive = true, onClick = clear)),
            onDismiss = { confirmDeclined = false },
        )
    }
}

@Composable
private fun Intro() {
    val colors = Osho.colors
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Icon(Icons.Rounded.Coffee, contentDescription = null, tint = colors.accent, modifier = Modifier.size(44.dp))
        Text(
            "Osho Talks is free and has no ads or tracking. If it has become part of your days, an optional tip helps me keep improving it.",
            style = Osho.typography.body,
            color = colors.label,
        )
        Text(
            "Choose a one-time tip or yearly support through Google Play. Every feature stays free for everyone.",
            style = Osho.typography.footnote,
            color = colors.secondaryLabel,
        )
    }
}

/** Builds a section from whichever rows apply, so card corners land on the real first and last. */
private fun LazyListScope.cardSection(key: String, rows: List<@Composable () -> Unit>) {
    rows.forEachIndexed { index, row ->
        item(key = "$key.$index") { CardRow(isFirst = index == 0, isLast = index == rows.lastIndex) { row() } }
    }
}

private fun LazyListScope.productsSection(state: TipJarUiState, actions: TipJarActions) {
    val rows = buildList<@Composable () -> Unit> {
        if (state.isLoading) {
            add {
                Row(
                    Modifier.fillMaxWidth().rowContentPadding(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    SmallSpinner()
                    Text("Loading tips…", style = Osho.typography.body, color = Osho.colors.secondaryLabel)
                }
            }
        }
        state.rows.forEach { row -> add { ProductRow(row) { actions.onPurchase(row) } } }
        state.tips.loadError?.let { error ->
            add { InfoText(error) }
            add { ActionRow("Try Again", enabled = !state.tips.isLoading && !state.tips.isPurchasing, onClick = actions.onRetryTips) }
        }
        state.annual.loadError?.let { error ->
            add { InfoText(error) }
            add { ActionRow("Retry Yearly Options", enabled = !state.annual.isBusy && !state.tips.isPurchasing, onClick = actions.onRetryAnnual) }
        }
    }
    cardSection("products", rows)
    state.tipCountFooter?.let { sectionFooter("products.footer", it) }
}

private fun LazyListScope.yearlySection(state: TipJarUiState, actions: TipJarActions, onDeclined: () -> Unit) {
    sectionHeader("yearly.header", "Yearly support")
    val annual = state.annual
    val rows = buildList<@Composable () -> Unit> {
        if (annual.pendingProductID != null) {
            add {
                InfoText(
                    "A yearly support request is awaiting approval. Another subscription can't be started until it is resolved.",
                    small = true,
                )
            }
            add { ActionRow("Check Pending Request", enabled = !annual.isBusy, onClick = actions.onRefreshStatus) }
            if (actions.onClearDeclinedRequest != null) add { ActionRow("Request Was Declined", enabled = true, onClick = onDeclined) }
        }
        if (annual.currentProductID != null) {
            add {
                Row(
                    Modifier.fillMaxWidth().rowContentPadding(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Icon(Icons.Outlined.FavoriteBorder, contentDescription = null, tint = Osho.colors.accent, modifier = Modifier.size(22.dp))
                    Text("Thank you for your yearly support", style = Osho.typography.body, color = Osho.colors.label)
                }
            }
            add {
                InfoText(
                    "Your Google account has a yearly support plan. You can change the amount, check its status, or cancel through Google Play.",
                    small = true,
                )
            }
        }
        add { ActionRow("Manage Subscriptions", enabled = true, onClick = actions.onManageSubscriptions) }
        add {
            ActionRow(
                if (annual.isRestoring) "Restoring…" else "Restore Subscription",
                enabled = !annual.isBusy && !state.tips.isPurchasing,
                onClick = actions.onRestore,
            )
        }
        annual.statusError?.let { error ->
            add { InfoText(error) }
            add { ActionRow("Check Subscription Status", enabled = !annual.isBusy, onClick = actions.onRefreshStatus) }
        }
        annual.restoreMessage?.let { message -> add { InfoText(message) } }
        add { ActionRow("Terms of Use", enabled = true) { actions.onOpenUrl(TERMS_OF_USE_URL) } }
        add { ActionRow("Privacy Policy", enabled = true) { actions.onOpenUrl(PRIVACY_POLICY_URL) } }
    }
    cardSection("yearly", rows)
    sectionFooter(
        "yearly.footer",
        "Yearly support is an auto-renewing subscription charged once a year unless cancelled before renewal. " +
            "Manage or cancel it in your Google Play subscriptions. One-time tips do not renew. Neither option unlocks features or content.",
    )
}

@Composable
private fun ProductRow(row: SupportRow, onClick: () -> Unit) {
    val colors = Osho.colors
    val stacked = isAccessibilityTextSize()
    val text: @Composable () -> Unit = {
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(row.product.name, style = Osho.typography.body, color = colors.label)
            Text(row.kind, style = Osho.typography.caption, color = colors.secondaryLabel)
            if (row.product.description.isNotEmpty()) {
                Text(row.product.description, style = Osho.typography.caption, color = colors.secondaryLabel)
            }
        }
    }
    val price: @Composable () -> Unit = {
        if (row.isPurchasing) {
            SmallSpinner()
        } else {
            Text(
                row.price,
                style = Osho.typography.subheadline.monospacedDigits(),
                fontWeight = FontWeight.SemiBold,
                color = colors.accent,
                maxLines = if (stacked) Int.MAX_VALUE else 1,
                modifier = Modifier
                    .clip(CircleShape)
                    .background(colors.accent.copy(alpha = 0.15f))
                    .padding(horizontal = 12.dp, vertical = 6.dp),
            )
        }
    }
    // A row that disables itself from its own tap (purchase starts) can keep its pressed ripple;
    // a fresh interaction source per enabled state drops it.
    val interactions = remember(row.enabled) { MutableInteractionSource() }
    val rowModifier = Modifier
        .fillMaxWidth()
        .clickable(interactions, ripple(), enabled = row.enabled, role = Role.Button, onClick = onClick)
        .semantics(mergeDescendants = true) {}
        .heightIn(min = 44.dp)
        .padding(horizontal = 16.dp, vertical = 10.dp)
    if (stacked) {
        Column(rowModifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
            text()
            price()
        }
    } else {
        Row(rowModifier, verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.weight(1f)) { text() }
            Spacer(Modifier.width(8.dp))
            price()
        }
    }
}

@Composable
private fun InfoText(text: String, small: Boolean = false) {
    Text(
        text,
        style = if (small) Osho.typography.footnote else Osho.typography.body,
        color = Osho.colors.secondaryLabel,
        modifier = Modifier.fillMaxWidth().rowContentPadding(vertical = 12.dp),
    )
}

@Composable
private fun ActionRow(label: String, enabled: Boolean, onClick: () -> Unit) {
    val accent = Osho.colors.accent
    Text(
        label,
        style = Osho.typography.body,
        color = if (enabled) accent else Osho.colors.tertiaryLabel,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .rowContentPadding(vertical = 15.dp),
    )
}

/** Pending stays inline so a later approval can still present its own confirmation. */
@Composable
private fun PendingBar(onGotIt: () -> Unit, modifier: Modifier = Modifier) {
    val colors = Osho.colors
    val bottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    Column(
        modifier
            .fillMaxWidth()
            .glass(RectangleShape, GlassMaterial.REGULAR, hazeState = null)
            .padding(16.dp)
            .padding(bottom = bottom),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(Icons.Outlined.Schedule, contentDescription = null, tint = colors.label, modifier = Modifier.size(20.dp))
            Text("Purchase pending", style = Osho.typography.headline, color = colors.label)
        }
        Text(
            "Your purchase is pending with Google Play. It may need approval, such as a family purchase request. You don't need to try again.",
            style = Osho.typography.footnote,
            color = colors.secondaryLabel,
        )
        Text(
            "Got It",
            style = Osho.typography.body,
            color = colors.accent,
            modifier = Modifier
                .heightIn(min = 44.dp)
                .clickable(role = Role.Button, onClick = onGotIt)
                .padding(vertical = 11.dp),
        )
    }
}
