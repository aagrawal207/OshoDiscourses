package com.agraabhi.oshodiscourses.feature.settings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ArrowOutward
import androidx.compose.material.icons.outlined.Mail
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.Cloud
import androidx.compose.material.icons.rounded.Code
import androidx.compose.material.icons.rounded.Coffee
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.StarBorder
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.agraabhi.oshodiscourses.core.domain.sync.SyncStatus
import com.agraabhi.oshodiscourses.core.model.AccentTheme
import com.agraabhi.oshodiscourses.core.model.Appearance
import com.agraabhi.oshodiscourses.core.model.LanguageFilter
import com.agraabhi.oshodiscourses.core.ui.components.CardRow
import com.agraabhi.oshodiscourses.core.ui.components.Grouped
import com.agraabhi.oshodiscourses.core.ui.components.GroupedPage
import com.agraabhi.oshodiscourses.core.ui.components.ListSectionFooter
import com.agraabhi.oshodiscourses.core.ui.components.SegmentedControl
import com.agraabhi.oshodiscourses.core.ui.components.SmallSpinner
import com.agraabhi.oshodiscourses.core.ui.components.rowContentPadding
import com.agraabhi.oshodiscourses.core.ui.components.sectionFooter
import com.agraabhi.oshodiscourses.core.ui.components.sectionHeader
import com.agraabhi.oshodiscourses.core.ui.theme.AccentPalette
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import com.agraabhi.oshodiscourses.feature.settings.ui.AccentSwatch
import com.agraabhi.oshodiscourses.feature.settings.ui.ToggleRow

internal class SettingsActions(
    val onLanguage: (LanguageFilter) -> Unit = {},
    val onAutoPlayNext: (Boolean) -> Unit = {},
    val onSmartDownload: (Boolean) -> Unit = {},
    val onSmartDelete: (Boolean) -> Unit = {},
    val onAllowCellular: (Boolean) -> Unit = {},
    val onOpenDenoise: () -> Unit = {},
    val onAppearance: (Appearance) -> Unit = {},
    val onPickAccent: (AccentTheme) -> Unit = {},
    val onShuffle: (Boolean) -> Unit = {},
    val onSignIn: () -> Unit = {},
    val onSyncNow: () -> Unit = {},
    val onSignOut: () -> Unit = {},
    val onOpenSupport: () -> Unit = {},
    val onRate: () -> Unit = {},
    val onSourceCode: () -> Unit = {},
    val onFeedback: () -> Unit = {},
)

/** Settings > About footer. The last paragraph names Google Drive where iOS names iCloud. */
internal val AboutFooter = listOf(
    "Acknowledgements: All discourses are copyright OSHO International Foundation. Audio is served from oshoworld.com.",
    "Noise reduction uses RNNoise (Xiph.Org, BSD 3-Clause) and DeepFilterNet by Hendrik Schröter (MIT/Apache-2.0).",
    "This app is an independent player for publicly available audio content hosted at oshoworld.com. Not affiliated with or endorsed by the Osho International Foundation.",
    "Your listening progress, bookmarks, and stats sync between your devices through your own Google Drive. Everything else stays on your phone. There are no accounts, no servers, and no tracking of any kind.",
)

@Composable
internal fun SettingsContent(state: SettingsUiState, versionName: String, actions: SettingsActions, modifier: Modifier = Modifier) {
    GroupedPage(
        title = "Settings",
        largeTitle = true,
        background = Osho.colors.systemGroupedBackground,
        modifier = modifier,
    ) {
        languageSection(state, actions)
        playerSection(state, actions)
        soundSection(state, actions)
        appearanceSection(state, actions)
        syncSection(state, actions)
        aboutSection(state, versionName, actions)
    }
}

private fun LazyListScope.languageSection(state: SettingsUiState, actions: SettingsActions) {
    sectionHeader("language.header", "Content Language", first = true)
    item(key = "language") {
        CardRow(isFirst = true, isLast = true) {
            SegmentedControl(
                options = LanguageFilter.entries,
                selected = state.settings.languageFilter,
                label = { it.rawValue },
                onSelect = actions.onLanguage,
                menuTitle = "Language",
                modifier = Modifier.rowContentPadding(vertical = 8.dp).semantics(mergeDescendants = false) {},
            )
        }
    }
}

private fun LazyListScope.playerSection(state: SettingsUiState, actions: SettingsActions) {
    sectionHeader("player.header", "Player & Downloads")
    val s = state.settings
    val toggles = listOf(
        Triple("Auto-Play Next", s.autoPlayNext, actions.onAutoPlayNext),
        Triple("Smart Download", s.smartDownload, actions.onSmartDownload),
        Triple("Smart Delete", s.smartDelete, actions.onSmartDelete),
        Triple("Download over Cellular", s.allowCellularDownloads, actions.onAllowCellular),
    )
    itemsIndexed(toggles, key = { _, t -> "toggle.${t.first}" }) { index, (label, checked, onChange) ->
        CardRow(isFirst = index == 0, isLast = index == toggles.lastIndex) {
            ToggleRow(label, checked, onChange)
        }
    }
    sectionFooter("player.footer", "Downloads use Wi-Fi only unless this is on. Each discourse is roughly 20–30 MB.")
}

private fun LazyListScope.soundSection(state: SettingsUiState, actions: SettingsActions) {
    sectionHeader("sound.header", "Sound")
    item(key = "denoise") {
        val colors = Osho.colors
        val on = state.settings.noiseReduction
        CardRow(isFirst = true, isLast = true) {
            Row(
                Modifier
                    .fillMaxWidth()
                    .clickable(role = Role.Button, onClick = actions.onOpenDenoise)
                    .semantics(mergeDescendants = true) {}
                    .rowContentPadding(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Icon(Icons.Rounded.GraphicEq, contentDescription = null, tint = colors.accent, modifier = Modifier.size(22.dp))
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("DeNoise", style = Osho.typography.body, color = colors.label)
                    Text(
                        if (on) state.settings.noiseReductionMode.displayName else "Noise reduction and volume boost",
                        style = Osho.typography.caption,
                        color = colors.secondaryLabel,
                    )
                }
                Text(if (on) "On" else "Off", style = Osho.typography.body, color = colors.secondaryLabel)
                Chevron()
            }
        }
    }
}

private fun LazyListScope.appearanceSection(state: SettingsUiState, actions: SettingsActions) {
    sectionHeader("appearance.header", "Appearance")
    item(key = "appearance.theme") {
        CardRow(isFirst = true, isLast = false) {
            SegmentedControl(
                options = listOf(Appearance.LIGHT, Appearance.SYSTEM, Appearance.DARK),
                selected = state.settings.appearance,
                label = { it.rawValue.replaceFirstChar(Char::uppercase) },
                onSelect = actions.onAppearance,
                menuTitle = "Theme",
                modifier = Modifier.rowContentPadding(vertical = 8.dp),
            )
        }
    }
    item(key = "appearance.swatches") {
        val dark = Osho.colors.isDark
        val effective = state.settings.effectiveAccentTheme
        CardRow(isFirst = false, isLast = false) {
            Row(
                Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState())
                    .heightIn(min = Grouped.rowMinHeight)
                    .padding(horizontal = Grouped.rowPadding, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                AccentTheme.entries.forEach { theme ->
                    AccentSwatch(
                        color = AccentPalette.color(theme, dark),
                        name = theme.displayName,
                        selected = theme == effective,
                        onClick = { actions.onPickAccent(theme) },
                    )
                }
            }
        }
    }
    item(key = "appearance.shuffle") {
        CardRow(isFirst = false, isLast = true) {
            ToggleRow("Shuffle Color Daily", state.settings.dailyAccentShuffle, actions.onShuffle)
        }
    }
    if (state.settings.dailyAccentShuffle) {
        sectionFooter("appearance.footer", "The accent color changes to a new one each day.")
    }
}

private fun LazyListScope.syncSection(state: SettingsUiState, actions: SettingsActions) {
    sectionHeader("sync.header", "Sync")
    val connected = state.isSyncConnected
    item(key = "sync.status") {
        val colors = Osho.colors
        CardRow(isFirst = true, isLast = !connected) {
            Row(
                Modifier.fillMaxWidth().rowContentPadding(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Icon(Icons.Rounded.Cloud, contentDescription = null, tint = colors.accent, modifier = Modifier.size(22.dp))
                Column(Modifier.weight(1f).semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("Google Drive", style = Osho.typography.body, color = colors.label)
                    Text(
                        state.syncSubtitle,
                        style = Osho.typography.caption,
                        color = if (state.sync is SyncStatus.Failed) colors.systemRed else colors.secondaryLabel,
                    )
                }
                when {
                    !connected -> TextAction("Sign In", colors.accent, bold = true, onClick = actions.onSignIn)
                    state.sync is SyncStatus.Syncing -> SmallSpinner()
                }
            }
        }
    }
    if (connected) {
        item(key = "sync.now") {
            CardRow(isFirst = false, isLast = false) {
                ButtonRow("Sync Now", Osho.colors.accent, enabled = state.sync !is SyncStatus.Syncing, onClick = actions.onSyncNow)
            }
        }
        item(key = "sync.signOut") {
            CardRow(isFirst = false, isLast = true) {
                ButtonRow("Stop Syncing", Osho.colors.systemRed, enabled = true, onClick = actions.onSignOut)
            }
        }
    }
    sectionFooter(
        "sync.footer",
        "Progress, bookmarks and stats sync through a hidden app folder in your own Google Drive. Settings stay on this device.",
    )
}

private fun LazyListScope.aboutSection(state: SettingsUiState, versionName: String, actions: SettingsActions) {
    sectionHeader("about.header", "About")
    item(key = "about.version") { CardRow(isFirst = true, isLast = false) { LabeledRow("Version", versionName) } }
    item(key = "about.series") { CardRow(isFirst = false, isLast = false) { LabeledRow("Series", "${state.seriesCount}") } }
    item(key = "about.discourses") { CardRow(isFirst = false, isLast = false) { LabeledRow("Discourses", "${state.discourseCount}") } }
    item(key = "about.support") {
        CardRow(isFirst = false, isLast = false) {
            LinkRow("Support Development", Icons.Rounded.Coffee, Osho.colors.accent, Icons.Rounded.ChevronRight, actions.onOpenSupport)
        }
    }
    item(key = "about.rate") {
        CardRow(isFirst = false, isLast = false) { LinkRow("Rate Osho Talks", Icons.Rounded.StarBorder, onClick = actions.onRate) }
    }
    item(key = "about.source") {
        CardRow(isFirst = false, isLast = false) { LinkRow("Source Code", Icons.Rounded.Code, onClick = actions.onSourceCode) }
    }
    item(key = "about.feedback") {
        CardRow(isFirst = false, isLast = true) { LinkRow("Send Feedback", Icons.Outlined.Mail, onClick = actions.onFeedback) }
    }
    item(key = "about.footer") {
        Column(Modifier.fillMaxWidth().padding(top = 8.dp), verticalArrangement = Arrangement.spacedBy(0.dp)) {
            AboutFooter.forEach { ListSectionFooter(it) }
        }
    }
}

@Composable
private fun LabeledRow(label: String, value: String) {
    Row(
        Modifier.fillMaxWidth().semantics(mergeDescendants = true) {}.rowContentPadding(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(label, style = Osho.typography.body, color = Osho.colors.label, modifier = Modifier.weight(1f))
        Text(value, style = Osho.typography.body, color = Osho.colors.secondaryLabel)
    }
}

/** The compact About rows: subheadline label with its icon, tinted trailing arrow (§1.6). */
@Composable
private fun LinkRow(
    title: String,
    icon: ImageVector,
    tint: Color = Osho.colors.label,
    trailing: ImageVector = Icons.Outlined.ArrowOutward,
    onClick: () -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(role = Role.Button, onClick = onClick)
            .semantics(mergeDescendants = true) {}
            .heightIn(min = 44.dp)
            .padding(horizontal = Grouped.rowPadding, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(20.dp))
        Text(title, style = Osho.typography.subheadline, color = tint, modifier = Modifier.padding(start = 16.dp).weight(1f))
        Icon(trailing, contentDescription = null, tint = Osho.colors.accentSecondary, modifier = Modifier.size(14.dp))
    }
}

@Composable
private fun ButtonRow(label: String, color: Color, enabled: Boolean, onClick: () -> Unit) {
    Text(
        label,
        style = Osho.typography.body,
        color = if (enabled) color else color.copy(alpha = 0.35f),
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .rowContentPadding(vertical = 15.dp),
    )
}

@Composable
private fun TextAction(label: String, color: Color, bold: Boolean, onClick: () -> Unit) {
    Text(
        label,
        style = Osho.typography.body,
        fontWeight = if (bold) FontWeight.SemiBold else null,
        color = color,
        modifier = Modifier
            .heightIn(min = 44.dp)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 4.dp, vertical = 11.dp),
    )
}

@Composable
private fun Chevron() {
    Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = Osho.colors.tertiaryLabel, modifier = Modifier.size(22.dp).width(22.dp))
}
