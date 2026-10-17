package com.agraabhi.oshodiscourses.core.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MenuDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.dp
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import com.agraabhi.oshodiscourses.core.ui.theme.ProvideElevatedSurfaces

/** One iOS menu row; destructive rows are red. */
data class MenuAction(
    val label: String,
    val icon: ImageVector?,
    val destructive: Boolean = false,
    /** Draws a divider above this row, as iOS does before a destructive group. */
    val dividerBefore: Boolean = false,
    val onClick: () -> Unit,
)

/** Material's DropdownMenu restyled as an iOS menu (ui-style.md §8): r 16, elevated card, 17 sp rows. */
@Composable
fun OshoMenu(
    expanded: Boolean,
    onDismiss: () -> Unit,
    actions: List<MenuAction>,
    offset: DpOffset = DpOffset.Zero,
) {
    ProvideElevatedSurfaces {
        val colors = Osho.colors
        DropdownMenu(
            expanded = expanded,
            onDismissRequest = onDismiss,
            offset = offset,
            shape = RoundedCornerShape(16.dp),
            containerColor = colors.secondarySystemGroupedBackground,
            shadowElevation = 12.dp,
            tonalElevation = 0.dp,
            modifier = Modifier.widthIn(min = 220.dp),
        ) {
            actions.forEach { action ->
                if (action.dividerBefore) HorizontalDivider(thickness = 0.5.dp, color = colors.separator)
                val tint = if (action.destructive) colors.systemRed else colors.label
                DropdownMenuItem(
                    text = { Text(action.label, style = Osho.typography.body, color = tint) },
                    leadingIcon = action.icon?.let { icon -> { Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(20.dp)) } },
                    onClick = {
                        onDismiss()
                        action.onClick()
                    },
                    colors = MenuDefaults.itemColors(),
                    contentPadding = PaddingValues(horizontal = 16.dp, vertical = 4.dp),
                )
            }
        }
    }
}

/**
 * The same iOS menu card with free content: [OshoMenuItem], [OshoMenuHeader], [OshoMenuNote]
 * and [OshoMenuDivider]. Used where rows need checks, sections or notes.
 */
@Composable
fun OshoMenu(
    expanded: Boolean,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
    offset: DpOffset = DpOffset(0.dp, 0.dp),
    maxWidth: Dp = 280.dp,
    content: @Composable () -> Unit,
) {
    DropdownMenu(
        expanded = expanded,
        onDismissRequest = onDismiss,
        modifier = modifier.widthIn(min = 220.dp, max = maxWidth),
        offset = offset,
        shape = RoundedCornerShape(16.dp),
        containerColor = Osho.colors.secondarySystemGroupedBackground,
        shadowElevation = 12.dp,
        tonalElevation = 0.dp,
        border = BorderStroke(0.5.dp, Osho.colors.separator),
    ) {
        content()
    }
}

/** A menu row; [checked] non-null reserves a trailing checkmark slot. */
@Composable
fun OshoMenuItem(
    text: String,
    icon: ImageVector?,
    onClick: () -> Unit,
    enabled: Boolean = true,
    destructive: Boolean = false,
    checked: Boolean? = null,
) {
    val color = if (destructive) Osho.colors.systemRed else Osho.colors.label
    DropdownMenuItem(
        text = { Text(text, style = Osho.typography.body) },
        onClick = onClick,
        enabled = enabled,
        leadingIcon = icon?.let { { Icon(it, contentDescription = null, modifier = Modifier.size(20.dp)) } },
        trailingIcon = checked?.let { on -> { if (on) Icon(Icons.Rounded.Check, contentDescription = null, modifier = Modifier.size(18.dp)) } },
        colors = MenuDefaults.itemColors(
            textColor = color,
            leadingIconColor = color,
            trailingIconColor = Osho.colors.label,
            disabledTextColor = Osho.colors.tertiaryLabel,
            disabledLeadingIconColor = Osho.colors.tertiaryLabel,
        ),
    )
}

/** iOS menu section title. */
@Composable
fun OshoMenuHeader(text: String) {
    Text(
        text,
        style = Osho.typography.footnote,
        color = Osho.colors.secondaryLabel,
        modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 4.dp),
    )
}

/** Non-interactive explanatory text inside a menu. */
@Composable
fun OshoMenuNote(text: String) {
    Text(
        text,
        style = Osho.typography.footnote,
        color = Osho.colors.secondaryLabel,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
    )
}

/** The thick iOS gap between menu sections. */
@Composable
fun OshoMenuDivider() {
    HorizontalDivider(Modifier.padding(vertical = 4.dp), thickness = 6.dp, color = Osho.colors.tertiarySystemFill)
}
