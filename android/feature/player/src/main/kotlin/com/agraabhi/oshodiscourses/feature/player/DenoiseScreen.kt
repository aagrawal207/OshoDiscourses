package com.agraabhi.oshodiscourses.feature.player

import androidx.activity.compose.BackHandler
import androidx.activity.compose.LocalOnBackPressedDispatcherOwner
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.PlayCircleOutline
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.HourglassEmpty
import androidx.compose.material.icons.rounded.RadioButtonUnchecked
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation3.runtime.NavKey
import com.agraabhi.oshodiscourses.core.domain.denoise.DenoiseState
import com.agraabhi.oshodiscourses.core.domain.player.AudioProcessingStatus
import com.agraabhi.oshodiscourses.core.model.BoostLevel
import com.agraabhi.oshodiscourses.core.model.DenoiseStrength
import com.agraabhi.oshodiscourses.core.model.NoiseReductionMode
import com.agraabhi.oshodiscourses.core.model.VoiceFocusPreset
import com.agraabhi.oshodiscourses.core.ui.bottomClearance
import com.agraabhi.oshodiscourses.core.ui.components.BackGlassButton
import com.agraabhi.oshodiscourses.core.ui.components.DisclosureChevron
import com.agraabhi.oshodiscourses.core.ui.components.GlassTextButton
import com.agraabhi.oshodiscourses.core.ui.components.GroupedDivider
import com.agraabhi.oshodiscourses.core.ui.components.GroupedSection
import com.agraabhi.oshodiscourses.core.ui.components.IosSwitch
import com.agraabhi.oshodiscourses.core.ui.components.MenuPickerRow
import com.agraabhi.oshodiscourses.core.ui.components.OshoIcons
import com.agraabhi.oshodiscourses.core.ui.components.SectionFooterText
import com.agraabhi.oshodiscourses.core.ui.components.SectionGap
import com.agraabhi.oshodiscourses.core.ui.components.SegmentedControl
import com.agraabhi.oshodiscourses.core.ui.components.SheetToolbar
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import com.agraabhi.oshodiscourses.feature.player.PlayerFormatting.StatusIcon
import kotlinx.serialization.Serializable

/** The shared DeNoise screen, pushed from Settings or opened from the player. */
@Serializable
data object DenoiseRoute : NavKey

/** Listening Mode and Quiet Speech are pushed inside this screen, as in iOS's NavigationStack. */
internal enum class DenoisePage { MAIN, MODE, VOICE }

/**
 * iOS `AudioEnhancementView`. Pushed from Settings it shows a back button ([onBack], or system
 * back when null); in the player sheet pass [onDone] for the trailing "Done" instead.
 */
@Composable
fun DenoiseScreen(
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
    onDone: (() -> Unit)? = null,
) {
    val viewModel = denoiseViewModel()
    val state by viewModel.state.collectAsStateWithLifecycle()
    var page by rememberSaveable { mutableStateOf(DenoisePage.MAIN) }
    BackHandler(enabled = page != DenoisePage.MAIN) { page = DenoisePage.MAIN }
    val dispatcher = LocalOnBackPressedDispatcherOwner.current?.onBackPressedDispatcher
    val back: () -> Unit = onBack ?: { dispatcher?.onBackPressed() }

    Box(modifier.fillMaxSize().background(Osho.colors.systemGroupedBackground)) {
        AnimatedContent(
            targetState = page,
            transitionSpec = {
                if (targetState != DenoisePage.MAIN) {
                    slideInHorizontally(tween(300)) { it } togetherWith slideOutHorizontally(tween(300)) { -it / 3 } + fadeOut(tween(300))
                } else {
                    slideInHorizontally(tween(300)) { -it / 3 } + fadeIn(tween(300)) togetherWith slideOutHorizontally(tween(300)) { it }
                }
            },
            label = "denoise-page",
        ) { shown ->
            when (shown) {
                DenoisePage.MAIN -> DenoisePageScaffold(
                    title = "DeNoise",
                    leading = { if (onDone == null) BackGlassButton(back) },
                    trailing = { if (onDone != null) GlassTextButton("Done", onClick = onDone) },
                    // iOS Forms leave a deep inset above a header-less first section.
                    topGap = 40.dp,
                ) {
                    DenoiseMainContent(
                        state = state,
                        onEnabled = viewModel::setEnabled,
                        onOpenMode = { page = DenoisePage.MODE },
                        onStrength = viewModel::setStrength,
                        onBoost = viewModel::setBoost,
                        onOpenVoice = { page = DenoisePage.VOICE },
                    )
                }
                DenoisePage.MODE -> DenoisePageScaffold("Listening Mode", leading = { BackGlassButton({ page = DenoisePage.MAIN }) }) {
                    ListeningModeContent(state.mode, onSelect = {
                        viewModel.setMode(it)
                        page = DenoisePage.MAIN
                    })
                }
                DenoisePage.VOICE -> DenoisePageScaffold("Quiet Speech", leading = { BackGlassButton({ page = DenoisePage.MAIN }) }, topGap = 40.dp) {
                    QuietSpeechContent(state.voiceFocus, onSelect = {
                        viewModel.setVoiceFocus(it)
                        page = DenoisePage.MAIN
                    })
                }
            }
        }
    }
}

@Composable
private fun DenoisePageScaffold(
    title: String,
    leading: @Composable RowScope.() -> Unit = {},
    trailing: @Composable RowScope.() -> Unit = {},
    topGap: Dp = 8.dp,
    content: @Composable ColumnScope.() -> Unit,
) {
    // Pushed pages sit over the tab bar and mini-player; in a sheet both are zero.
    val navBar = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    val bottom = maxOf(bottomClearance, navBar) + 16.dp
    Column(Modifier.fillMaxSize().background(Osho.colors.systemGroupedBackground).statusBarsPadding()) {
        SheetToolbar(title, leading = leading, trailing = trailing)
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(top = topGap, bottom = bottom),
            content = content,
        )
    }
}

/** Accessibility sizes swap segmented rows for menus, which iOS does at the same threshold. */
@Composable
private fun isAccessibilitySize(): Boolean = LocalDensity.current.fontScale >= 1.6f

@Composable
internal fun DenoiseMainContent(
    state: DenoiseState,
    onEnabled: (Boolean) -> Unit,
    onOpenMode: () -> Unit,
    onStrength: (DenoiseStrength) -> Unit,
    onBoost: (BoostLevel) -> Unit,
    onOpenVoice: () -> Unit,
) {
    val colors = Osho.colors
    val large = isAccessibilitySize()

    GroupedSection(footer = { StatusFooter(state.status) }) {
        Column(
            Modifier
                .fillMaxWidth()
                .toggleable(value = state.isEnabled, role = Role.Switch, onValueChange = onEnabled)
                .padding(horizontal = 16.dp, vertical = 15.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Enable DeNoise", style = Osho.typography.headline, color = colors.label, modifier = Modifier.weight(1f))
                IosSwitch(checked = state.isEnabled, onCheckedChange = null)
            }
            Text(
                "Reduce recording noise and make quiet audio easier to hear.",
                style = Osho.typography.subheadline,
                color = colors.secondaryLabel,
            )
        }
    }
    SectionGap()

    GroupedSection(header = "Listening Mode") {
        Row(
            Modifier
                .fillMaxWidth()
                .clickable(onClick = onOpenMode)
                .clearAndSetSemantics {
                    contentDescription = "Listening mode"
                    stateDescription = "${state.mode.displayName}. ${state.mode.batteryNote}"
                    role = Role.Button
                    onClick(label = "show the recommended mode and lighter alternatives") { onOpenMode(); true }
                }
                .padding(horizontal = 16.dp, vertical = 15.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            EnhancementModeLabel(state.mode, Modifier.weight(1f))
            DisclosureChevron()
        }
    }
    SectionGap()

    if (state.isEnabled) {
        GroupedSection(header = "Noise Reduction", footer = { SectionFooterText(state.strength.detail) }) {
            val labels = DenoiseStrength.entries.map { it.label }
            val index = DenoiseStrength.entries.indexOf(state.strength)
            if (large) {
                MenuPickerRow("Amount", labels, index, onSelect = { onStrength(DenoiseStrength.entries[it]) })
            } else {
                SegmentedControl(
                    labels,
                    index,
                    onSelect = { onStrength(DenoiseStrength.entries[it]) },
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp).semantics { contentDescription = "Amount" },
                )
            }
        }
        SectionGap()
    }

    GroupedSection(header = "Volume Boost", footer = { SectionFooterText(PlayerFormatting.boostExplanation(state)) }) {
        val level = PlayerFormatting.boostLevel(state.boostGain)
        val levelLabel = if (state.isBoostAvailable) "Level" else "Saved level"
        val labels = BoostLevel.entries.map { it.label }
        if (large) {
            MenuPickerRow(levelLabel, labels, level.ordinal, onSelect = { onBoost(BoostLevel.entries[it]) }, enabled = state.isEnabled)
        } else {
            Column(
                Modifier.padding(horizontal = 16.dp, vertical = 15.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Row {
                    Text(levelLabel, style = Osho.typography.body, color = colors.label, modifier = Modifier.weight(1f))
                    Text(level.label, style = Osho.typography.body, color = colors.secondaryLabel)
                }
                SegmentedControl(
                    labels,
                    level.ordinal,
                    onSelect = { onBoost(BoostLevel.entries[it]) },
                    enabled = state.isEnabled,
                    modifier = Modifier.semantics { contentDescription = levelLabel },
                )
            }
        }
    }

    if (state.isEnabled && state.mode == NoiseReductionMode.DEEP_FILTER_NET) {
        SectionGap()
        GroupedSection(footer = { SectionFooterText("Your choices apply to all discourses. Results vary by recording.") }) {
            Row(
                Modifier
                    .fillMaxWidth()
                    .heightIn(min = 52.dp)
                    .clickable(role = Role.Button, onClick = onOpenVoice)
                    .semantics(mergeDescendants = true) { stateDescription = state.voiceFocus.displayName }
                    .padding(start = 16.dp, end = 12.dp, top = 11.dp, bottom = 11.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text("Fine-tune the voice", style = Osho.typography.body, color = colors.label, modifier = Modifier.weight(1f))
                Text(state.voiceFocus.displayName, style = Osho.typography.body, color = colors.secondaryLabel)
                DisclosureChevron()
            }
        }
    }
}

@Composable
private fun StatusFooter(status: AudioProcessingStatus) {
    val colors = Osho.colors
    val color = if (status.isIssue) colors.systemOrange else colors.secondaryLabel
    val icon: ImageVector = when (PlayerFormatting.statusIcon(status)) {
        StatusIcon.ISSUE -> Icons.Outlined.ErrorOutline
        StatusIcon.ACTIVE -> Icons.Rounded.CheckCircle
        StatusIcon.WAITING -> Icons.Outlined.PlayCircleOutline
        StatusIcon.PREPARING -> Icons.Rounded.HourglassEmpty
        StatusIcon.IDLE -> Icons.Rounded.GraphicEq
    }
    Row(horizontalArrangement = Arrangement.spacedBy(5.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(14.dp))
        Text(status.label, style = Osho.typography.caption, fontWeight = FontWeight.Medium, color = color)
    }
    if (status.isIssue) SectionFooterText(status.detail, color)
}

@Composable
private fun EnhancementModeLabel(mode: NoiseReductionMode, modifier: Modifier = Modifier) {
    val colors = Osho.colors
    val batteryColor = if (mode == NoiseReductionMode.DEEP_FILTER_NET) colors.accent else colors.secondaryLabel
    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(mode.displayName, style = Osho.typography.headline, color = colors.label)
        Text(mode.detail, style = Osho.typography.subheadline, color = colors.secondaryLabel)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(OshoIcons.Battery50, contentDescription = null, tint = batteryColor, modifier = Modifier.size(width = 26.dp, height = 12.dp))
            Text(mode.batteryNote, style = Osho.typography.caption, fontWeight = FontWeight.Medium, color = batteryColor)
        }
    }
}

@Composable
private fun SelectionIndicator(selected: Boolean) {
    val colors = Osho.colors
    Icon(
        if (selected) Icons.Rounded.CheckCircle else Icons.Rounded.RadioButtonUnchecked,
        contentDescription = null,
        tint = if (selected) colors.accent else colors.secondaryLabel,
        modifier = Modifier.size(24.dp),
    )
}

@Composable
private fun OptionRow(selected: Boolean, onClick: () -> Unit, content: @Composable RowScope.() -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(role = Role.RadioButton, onClick = onClick)
            .semantics { this.selected = selected }
            .padding(horizontal = 16.dp, vertical = 15.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        content()
        SelectionIndicator(selected)
    }
}

@Composable
internal fun ListeningModeContent(selected: NoiseReductionMode, onSelect: (NoiseReductionMode) -> Unit) {
    GroupedSection(header = "Recommended") {
        OptionRow(selected == NoiseReductionMode.DEEP_FILTER_NET, { onSelect(NoiseReductionMode.DEEP_FILTER_NET) }) {
            EnhancementModeLabel(NoiseReductionMode.DEEP_FILTER_NET, Modifier.weight(1f))
        }
    }
    SectionGap()
    val others = NoiseReductionMode.entries.filter { it != NoiseReductionMode.DEEP_FILTER_NET }
    GroupedSection(
        header = "Other Options",
        footer = { SectionFooterText("Try a lighter option if you prefer its sound or want to save battery.") },
    ) {
        others.forEachIndexed { index, mode ->
            if (index > 0) GroupedDivider()
            OptionRow(selected == mode, { onSelect(mode) }) { EnhancementModeLabel(mode, Modifier.weight(1f)) }
        }
    }
}

@Composable
internal fun QuietSpeechContent(selected: VoiceFocusPreset, onSelect: (VoiceFocusPreset) -> Unit) {
    val colors = Osho.colors
    GroupedSection {
        VoiceFocusPreset.entries.forEachIndexed { index, preset ->
            if (index > 0) GroupedDivider()
            OptionRow(selected == preset, { onSelect(preset) }) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(preset.displayName, style = Osho.typography.headline, color = colors.label)
                    Text(preset.detail, style = Osho.typography.subheadline, color = colors.secondaryLabel)
                }
            }
        }
    }
    Spacer(Modifier.height(8.dp))
}
