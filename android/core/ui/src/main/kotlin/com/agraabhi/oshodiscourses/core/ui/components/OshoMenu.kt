package com.agraabhi.oshodiscourses.core.ui.components

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
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
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
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

/** iOS 26 menus are much rounder than iOS 18's; measured from the reference screens. */
val MenuCornerRadius = 26.dp

/** Material's DropdownMenu restyled as an iOS 26 menu (ui-style.md §8): elevated card, 17 sp rows, accent icons. */
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
            shape = RoundedCornerShape(MenuCornerRadius),
            containerColor = colors.secondarySystemGroupedBackground,
            shadowElevation = 12.dp,
            tonalElevation = 0.dp,
            modifier = Modifier.widthIn(min = 220.dp),
        ) {
            actions.forEach { action ->
                if (action.dividerBefore) HorizontalDivider(thickness = 0.5.dp, color = colors.separator)
                val tint = if (action.destructive) colors.systemRed else colors.label
                val iconTint = if (action.destructive) colors.systemRed else colors.accent
                DropdownMenuItem(
                    text = { Text(action.label, style = Osho.typography.body, color = tint) },
                    leadingIcon = action.icon?.let { icon -> { Icon(icon, contentDescription = null, tint = iconTint, modifier = Modifier.size(20.dp)) } },
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
    reservesCheckColumn: Boolean = false,
    content: @Composable () -> Unit,
) {
    DropdownMenu(
        expanded = expanded,
        onDismissRequest = onDismiss,
        modifier = modifier.widthIn(min = if (reservesCheckColumn) 250.dp else 220.dp, max = maxWidth),
        offset = offset,
        shape = RoundedCornerShape(MenuCornerRadius),
        containerColor = Osho.colors.secondarySystemGroupedBackground,
        shadowElevation = 12.dp,
        tonalElevation = 0.dp,
    ) {
        CompositionLocalProvider(LocalReservesCheckColumn provides reservesCheckColumn, content = content)
    }
}

/** iOS 26 menus with a toggle keep a leading column for its checkmark, and indent every row to match. */
private val LocalReservesCheckColumn = staticCompositionLocalOf { false }
private val CheckColumnWidth = 26.dp

/** A menu row; [checked] non-null shows a checkmark when on (leading if the menu reserves a column). */
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
    val reserve = LocalReservesCheckColumn.current
    DropdownMenuItem(
        text = { Text(text, style = Osho.typography.body) },
        onClick = onClick,
        enabled = enabled,
        leadingIcon = if (reserve || icon != null) {
            {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    if (reserve) {
                        Box(Modifier.width(CheckColumnWidth), contentAlignment = Alignment.CenterStart) {
                            if (checked == true) Icon(Icons.Rounded.Check, contentDescription = null, tint = Osho.colors.label, modifier = Modifier.size(18.dp))
                        }
                    }
                    if (icon != null) Icon(icon, contentDescription = null, modifier = Modifier.size(22.dp))
                }
            }
        } else {
            null
        },
        trailingIcon = if (reserve) null else checked?.let { on -> { if (on) Icon(Icons.Rounded.Check, contentDescription = null, modifier = Modifier.size(18.dp)) } },
        colors = MenuDefaults.itemColors(
            textColor = color,
            leadingIconColor = if (destructive) color else Osho.colors.accent,
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
        modifier = Modifier.fillMaxWidth().padding(start = menuTextInset(), end = 16.dp, top = 8.dp, bottom = 4.dp),
    )
}

/** Headers and notes line up with the row icons. */
@Composable
private fun menuTextInset(): Dp = if (LocalReservesCheckColumn.current) 12.dp + CheckColumnWidth else 16.dp

/** Non-interactive text inside a menu, drawn like a disabled row as iOS does. */
@Composable
fun OshoMenuNote(text: String) {
    Text(
        text,
        style = Osho.typography.body,
        color = Osho.colors.tertiaryLabel,
        modifier = Modifier.fillMaxWidth().padding(start = menuTextInset(), end = 16.dp, top = 6.dp, bottom = 6.dp),
    )
}

/** The hairline iOS 26 draws between menu sections, inset like the rows. */
@Composable
fun OshoMenuDivider() {
    HorizontalDivider(Modifier.padding(horizontal = 16.dp, vertical = 4.dp), thickness = 0.5.dp, color = Osho.colors.separator)
}
