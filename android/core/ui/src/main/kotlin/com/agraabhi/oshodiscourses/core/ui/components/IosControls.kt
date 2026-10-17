package com.agraabhi.oshodiscourses.core.ui.components

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.drag
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.UnfoldMore
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.setProgress
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.agraabhi.oshodiscourses.core.ui.theme.Osho

private val ThumbWidth = 38.dp
private val ThumbHeight = 24.dp
private val TrackHeight = 4.dp

/**
 * iOS 26 slider: a thin accent track and a white capsule thumb (ui-style.md §3.3). Custom
 * because Material's thumb and track gap read as Android; a press anywhere starts a scrub.
 */
@Composable
fun IosSlider(
    value: Float,
    onValueChange: (Float) -> Unit,
    modifier: Modifier = Modifier,
    valueRange: ClosedFloatingPointRange<Float> = 0f..1f,
    steps: Int = 0,
    enabled: Boolean = true,
    onValueChangeStarted: () -> Unit = {},
    onValueChangeFinished: () -> Unit = {},
) {
    val colors = Osho.colors
    val currentOnChange by rememberUpdatedState(onValueChange)
    val currentOnStart by rememberUpdatedState(onValueChangeStarted)
    val currentOnFinish by rememberUpdatedState(onValueChangeFinished)
    val range by rememberUpdatedState(valueRange)
    val span = (valueRange.endInclusive - valueRange.start).takeIf { it > 0f } ?: 1f
    val fraction = ((value - valueRange.start) / span).coerceIn(0f, 1f)
    val density = LocalDensity.current
    val thumbWidthPx = with(density) { ThumbWidth.toPx() }

    BoxWithConstraints(
        modifier = modifier
            .fillMaxWidth()
            .height(44.dp)
            .semantics {
                progressBarRangeInfo = ProgressBarRangeInfo(value, valueRange, steps)
                if (!enabled) disabled()
                setProgress { target ->
                    currentOnChange(target.coerceIn(range.start, range.endInclusive))
                    currentOnFinish()
                    true
                }
            }
            .pointerInput(enabled) {
                if (!enabled) return@pointerInput
                fun valueAt(x: Float): Float {
                    val usable = (size.width - thumbWidthPx).coerceAtLeast(1f)
                    val f = ((x - thumbWidthPx / 2) / usable).coerceIn(0f, 1f)
                    return range.start + f * (range.endInclusive - range.start)
                }
                awaitEachGesture {
                    val down = awaitFirstDown()
                    down.consume()
                    currentOnStart()
                    currentOnChange(valueAt(down.position.x))
                    drag(down.id) { change ->
                        change.consume()
                        currentOnChange(valueAt(change.position.x))
                    }
                    currentOnFinish()
                }
            },
        contentAlignment = Alignment.CenterStart,
    ) {
        val usable = maxWidth - ThumbWidth
        val thumbX = usable * fraction
        Canvas(Modifier.fillMaxWidth().height(TrackHeight)) {
            val radius = CornerRadius(size.height / 2)
            drawRoundRect(colors.systemFill, cornerRadius = radius)
            val activeEnd = thumbWidthPx / 2 + (size.width - thumbWidthPx) * fraction
            drawRoundRect(
                if (enabled) colors.accent else colors.systemGray,
                size = Size(activeEnd, size.height),
                cornerRadius = radius,
            )
        }
        Box(
            Modifier
                .offset(x = thumbX)
                .size(ThumbWidth, ThumbHeight)
                .shadow(4.dp, CircleShape, ambientColor = Color.Black.copy(alpha = 0.25f), spotColor = Color.Black.copy(alpha = 0.25f))
                .background(Color.White, CircleShape)
                .border(0.5.dp, Color.Black.copy(alpha = 0.04f), CircleShape),
        )
    }
}

/** iOS 26 Toggle metrics: a 63 x 28 capsule track around a 39 x 24 capsule thumb. */
private val SwitchTrackWidth = 63.dp
private val SwitchTrackHeight = 28.dp
private val SwitchThumbWidth = 39.dp
private val SwitchThumbHeight = 24.dp

/** iOS 26 Toggle (ui-style.md §3.3): accent track when on, a gray track when off, no icon. */
@Composable
fun IosSwitch(checked: Boolean, onCheckedChange: ((Boolean) -> Unit)?, modifier: Modifier = Modifier, enabled: Boolean = true) {
    val colors = Osho.colors
    // iOS 26 draws the off track darker than systemFill; sampled from the reference screens.
    val offTrack = if (colors.isDark) Color(0xFF5A5A5E) else Color(0xFFC5C5C7)
    val track by animateColorAsState(if (checked) colors.accent else offTrack, tween(200), label = "switchTrack")
    val travel = SwitchTrackWidth - SwitchThumbWidth - 4.dp
    val thumbX by animateDpAsState(if (checked) travel else 0.dp, spring(dampingRatio = 0.8f, stiffness = Spring.StiffnessMedium), label = "switchThumb")
    Box(
        modifier
            .size(SwitchTrackWidth, SwitchTrackHeight)
            .alpha(if (enabled) 1f else 0.4f)
            .then(
                if (onCheckedChange != null) {
                    Modifier.toggleable(
                        value = checked,
                        enabled = enabled,
                        role = Role.Switch,
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        onValueChange = onCheckedChange,
                    )
                } else {
                    Modifier
                },
            )
            .background(track, CircleShape)
            .padding(2.dp),
    ) {
        Box(
            Modifier
                .offset(x = thumbX)
                .size(SwitchThumbWidth, SwitchThumbHeight)
                .shadow(2.dp, CircleShape, ambientColor = Color.Black.copy(alpha = 0.2f), spotColor = Color.Black.copy(alpha = 0.2f))
                .background(Color.White, CircleShape),
        )
    }
}

/**
 * iOS segmented Picker (ui-style.md §3.3): a capsule track with a sliding thumb. Material's
 * SegmentedButton is outlined and reads very differently.
 */
@Composable
fun SegmentedControl(
    options: List<String>,
    selectedIndex: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    val colors = Osho.colors
    val thumbColor = if (colors.isDark) Color(0xFF636366) else Color.White
    BoxWithConstraints(
        modifier = modifier
            .fillMaxWidth()
            .height(32.dp)
            .background(colors.tertiarySystemFill, CircleShape)
            .padding(2.dp),
    ) {
        val segment = maxWidth / options.size.coerceAtLeast(1)
        val thumbOffset by animateDpAsState(segment * selectedIndex.coerceAtLeast(0), tween(200), label = "segment")
        if (selectedIndex in options.indices) {
            Box(
                Modifier
                    .offset(x = thumbOffset)
                    .width(segment)
                    .fillMaxHeight()
                    .shadow(if (colors.isDark) 0.dp else 2.dp, CircleShape, ambientColor = Color.Black.copy(alpha = 0.12f), spotColor = Color.Black.copy(alpha = 0.12f))
                    .background(thumbColor, CircleShape),
            )
        }
        Row(Modifier.fillMaxWidth().fillMaxHeight().selectableGroup()) {
            options.forEachIndexed { index, label ->
                val selected = index == selectedIndex
                Box(
                    Modifier
                        .weight(1f)
                        .fillMaxHeight()
                        .selectable(selected = selected, enabled = enabled, role = Role.Tab, onClick = { onSelect(index) }),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        label,
                        style = Osho.typography.segment,
                        fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium,
                        // A disabled iOS segmented control keeps its track and thumb and grays only the labels.
                        color = if (enabled) colors.label else colors.secondaryLabel,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        textAlign = TextAlign.Center,
                    )
                }
            }
        }
    }
}

/**
 * iOS `.pickerStyle(.menu)` row for accessibility text sizes, where a segmented row cannot fit:
 * label, accent value with an up-down chevron, and a menu of options.
 */
@Composable
fun MenuPickerRow(
    label: String,
    options: List<String>,
    selectedIndex: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    contentPadding: PaddingValues = PaddingValues(horizontal = 16.dp, vertical = 11.dp),
) {
    val colors = Osho.colors
    var expanded by remember { mutableStateOf(false) }
    Box(modifier) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .alpha(if (enabled) 1f else 0.4f)
                .clickable(enabled = enabled, role = Role.DropdownList) { expanded = true }
                .padding(contentPadding),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(label, style = Osho.typography.body, color = colors.label, modifier = Modifier.weight(1f))
            Text(options.getOrElse(selectedIndex) { "" }, style = Osho.typography.body, color = colors.accent)
            Icon(Icons.Rounded.UnfoldMore, contentDescription = null, tint = colors.accent, modifier = Modifier.size(18.dp))
        }
        DropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
            shape = RoundedCornerShape(16.dp),
            containerColor = colors.secondarySystemGroupedBackground,
        ) {
            options.forEachIndexed { index, option ->
                DropdownMenuItem(
                    text = { Text(option, style = Osho.typography.body, color = colors.label) },
                    trailingIcon = if (index == selectedIndex) {
                        { Icon(Icons.Rounded.Check, contentDescription = null, tint = colors.label, modifier = Modifier.size(18.dp)) }
                    } else {
                        null
                    },
                    onClick = {
                        expanded = false
                        onSelect(index)
                    },
                )
            }
        }
    }
}

/** Disabled iOS controls dim to about a third. */
const val DisabledAlpha = 0.35f

/** iOS switches to stacked layouts and menu pickers at accessibility text sizes (ui-style.md §0). */
@Composable
fun isAccessibilityTextSize(): Boolean = LocalDensity.current.fontScale >= 1.6f

/**
 * A segmented picker over values. At accessibility text sizes it becomes a [MenuPickerRow]
 * titled [menuTitle], as SwiftUI does; the caller's row supplies the padding.
 */
@Composable
fun <T> SegmentedControl(
    options: List<T>,
    selected: T,
    label: (T) -> String,
    onSelect: (T) -> Unit,
    menuTitle: String,
    modifier: Modifier = Modifier,
) {
    val labels = options.map(label)
    val index = options.indexOf(selected)
    if (isAccessibilityTextSize()) {
        MenuPickerRow(menuTitle, labels, index, onSelect = { onSelect(options[it]) }, modifier = modifier, contentPadding = PaddingValues(0.dp))
    } else {
        SegmentedControl(labels, index, onSelect = { onSelect(options[it]) }, modifier = modifier)
    }
}
