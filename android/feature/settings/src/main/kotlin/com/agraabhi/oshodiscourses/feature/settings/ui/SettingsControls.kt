package com.agraabhi.oshodiscourses.feature.settings.ui

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.UnfoldMore
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.DialogProperties
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import com.agraabhi.oshodiscourses.core.ui.theme.ProvideElevatedSurfaces

/** iOS switches to menu pickers at accessibility text sizes (ui-style.md §0). */
@Composable
internal fun isAccessibilityTextSize(): Boolean = LocalDensity.current.fontScale >= 1.6f

/**
 * iOS segmented `Picker`: a capsule track with a raised capsule thumb. At accessibility sizes
 * it becomes a labelled menu row, as SwiftUI does.
 */
@Composable
internal fun <T> SegmentedControl(
    options: List<T>,
    selected: T,
    label: (T) -> String,
    onSelect: (T) -> Unit,
    menuTitle: String,
    modifier: Modifier = Modifier,
) {
    val colors = Osho.colors
    if (isAccessibilityTextSize()) {
        var expanded by remember { mutableStateOf(false) }
        Row(
            modifier
                .fillMaxWidth()
                .clickable(role = Role.DropdownList) { expanded = true }
                .semantics(mergeDescendants = true) {},
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(menuTitle, style = Osho.typography.body, color = colors.label, modifier = Modifier.weight(1f))
            Box {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(label(selected), style = Osho.typography.body, color = colors.secondaryLabel)
                    Icon(Icons.Rounded.UnfoldMore, contentDescription = null, tint = colors.secondaryLabel, modifier = Modifier.size(20.dp))
                }
                IosMenu(
                    expanded = expanded,
                    onDismiss = { expanded = false },
                    items = options.map { option ->
                        MenuAction(label(option), if (option == selected) Icons.Rounded.Check else null) { onSelect(option) }
                    },
                )
            }
        }
        return
    }
    val thumb = if (colors.isDark) Color(0xFF636366) else Color.White
    Row(
        modifier
            .fillMaxWidth()
            .heightIn(min = 36.dp)
            .clip(CircleShape)
            .background(colors.tertiarySystemFill)
            .padding(2.dp)
            .selectableGroup(),
    ) {
        options.forEach { option ->
            val isSelected = option == selected
            val background by animateColorAsState(
                if (isSelected) thumb else Color.Transparent,
                tween(200, easing = FastOutSlowInEasing),
                label = "segment",
            )
            Box(
                Modifier
                    .weight(1f)
                    .heightIn(min = 32.dp)
                    .then(if (isSelected && !colors.isDark) Modifier.shadow(2.dp, CircleShape) else Modifier)
                    .clip(CircleShape)
                    .background(background)
                    .selectable(selected = isSelected, role = Role.Tab) { onSelect(option) }
                    .padding(horizontal = 4.dp, vertical = 6.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    label(option),
                    style = Osho.typography.segment,
                    fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Medium,
                    color = colors.label,
                    textAlign = TextAlign.Center,
                    maxLines = 1,
                )
            }
        }
    }
}

/** `Toggle` tinted with the accent: white thumb, no icon or outline. */
@Composable
internal fun OshoSwitch(checked: Boolean, onCheckedChange: ((Boolean) -> Unit)?, modifier: Modifier = Modifier) {
    val colors = Osho.colors
    Switch(
        checked = checked,
        onCheckedChange = onCheckedChange,
        modifier = modifier,
        // A fixed-size thumb keeps the off state as large as the on state, like iOS.
        thumbContent = { Box(Modifier.size(24.dp)) },
        colors = SwitchDefaults.colors(
            checkedThumbColor = Color.White,
            checkedTrackColor = colors.accent,
            checkedBorderColor = Color.Transparent,
            uncheckedThumbColor = Color.White,
            uncheckedTrackColor = colors.systemFill,
            uncheckedBorderColor = Color.Transparent,
        ),
    )
}

/** A Form row with a label and a trailing switch; the whole row toggles. */
@Composable
internal fun ToggleRow(label: String, checked: Boolean, onCheckedChange: (Boolean) -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .toggleable(value = checked, role = Role.Switch, onValueChange = onCheckedChange)
            .rowContentPadding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(label, style = Osho.typography.body, color = Osho.colors.label, modifier = Modifier.weight(1f))
        OshoSwitch(checked, onCheckedChange = null)
    }
}

/** One accent swatch: 27 dp fill, 3 dp gap and a 2 dp ring when selected (iOS Settings). */
@Composable
internal fun AccentSwatch(color: Color, name: String, selected: Boolean, onClick: () -> Unit) {
    val ring by animateColorAsState(if (selected) color else Color.Transparent, tween(200, easing = FastOutSlowInEasing), label = "ring")
    Box(
        Modifier
            .size(33.dp)
            .border(2.dp, ring, CircleShape)
            .clip(CircleShape)
            .selectable(selected = selected, role = Role.RadioButton, onClick = onClick)
            .semantics { contentDescription = name }
            .padding(3.dp)
            .background(color, CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        if (selected) Icon(Icons.Rounded.Check, contentDescription = null, tint = Color.White, modifier = Modifier.size(14.dp))
    }
}

/** SwiftUI `.alert` with one OK button (ui-style.md §8). */
@Composable
internal fun IosAlert(title: String, message: String, onDismiss: () -> Unit) {
    ProvideElevatedSurfaces {
        val colors = Osho.colors
        AlertDialog(
            onDismissRequest = onDismiss,
            // iOS alerts are a fixed narrow card, not Material's 280-560 dp range.
            modifier = Modifier.widthIn(max = 300.dp),
            properties = DialogProperties(usePlatformDefaultWidth = false),
            shape = RoundedCornerShape(22.dp),
            containerColor = colors.secondarySystemGroupedBackground,
            title = {
                Text(title, style = Osho.typography.headline, color = colors.label, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
            },
            text = {
                Text(message, style = Osho.typography.footnote, color = colors.label, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
            },
            confirmButton = {
                TextButton(onClick = onDismiss, modifier = Modifier.fillMaxWidth()) {
                    Text("OK", style = Osho.typography.body, fontWeight = FontWeight.SemiBold, color = colors.accent)
                }
            },
        )
    }
}
