package com.agraabhi.oshodiscourses.feature.settings.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MenuDefaults
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import com.agraabhi.oshodiscourses.core.ui.theme.ProvideElevatedSurfaces

/** An item in a restyled iOS menu. */
internal data class MenuAction(
    val label: String,
    val icon: ImageVector?,
    val destructive: Boolean = false,
    val onClick: () -> Unit,
)

/**
 * SwiftUI `Menu` / `.contextMenu` look: a rounded elevated card, 17 sp items with their icon,
 * destructive items red. `null` entries draw a divider.
 */
@Composable
internal fun IosMenu(expanded: Boolean, onDismiss: () -> Unit, items: List<MenuAction?>) {
    val elevated = Osho.colors.elevated()
    DropdownMenu(
        expanded = expanded,
        onDismissRequest = onDismiss,
        shape = RoundedCornerShape(16.dp),
        containerColor = elevated.secondarySystemGroupedBackground,
        shadowElevation = 12.dp,
        tonalElevation = 0.dp,
        modifier = Modifier.widthIn(min = 220.dp),
    ) {
        items.forEach { item ->
            if (item == null) {
                HorizontalDivider(color = elevated.tertiarySystemFill, thickness = 6.dp)
                return@forEach
            }
            val tint = if (item.destructive) elevated.systemRed else elevated.label
            DropdownMenuItem(
                text = { Text(item.label, style = Osho.typography.body, color = tint) },
                onClick = {
                    onDismiss()
                    item.onClick()
                },
                trailingIcon = item.icon?.let { icon -> { Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(20.dp)) } },
                colors = MenuDefaults.itemColors(textColor = tint),
            )
        }
    }
}

/** One button in an [ActionSheet]. */
internal data class SheetAction(val label: String, val destructive: Boolean = false, val onClick: () -> Unit)

/**
 * iPhone `confirmationDialog` with a visible title: a bottom card of actions and a separate
 * Cancel card (ui-style.md §8).
 */
@Composable
internal fun ActionSheet(
    title: String,
    message: String?,
    actions: List<SheetAction>,
    onDismiss: () -> Unit,
) {
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        ProvideElevatedSurfaces {
            val colors = Osho.colors
            val bottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
            Box(
                Modifier
                    .fillMaxSize()
                    .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onDismiss),
                contentAlignment = Alignment.BottomCenter,
            ) {
                Column(
                    Modifier
                        .widthIn(max = 480.dp)
                        .padding(horizontal = 8.dp)
                        .padding(bottom = bottom + 8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    SheetCard {
                        Column(
                            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(4.dp),
                        ) {
                            Text(
                                title,
                                style = Osho.typography.footnote,
                                fontWeight = FontWeight.SemiBold,
                                color = colors.secondaryLabel,
                                textAlign = TextAlign.Center,
                            )
                            if (message != null) {
                                Text(message, style = Osho.typography.footnote, color = colors.secondaryLabel, textAlign = TextAlign.Center)
                            }
                        }
                        actions.forEach { action ->
                            HorizontalDivider(color = colors.separator, thickness = 0.5.dp)
                            SheetButton(action.label, if (action.destructive) colors.systemRed else colors.accent, bold = false) {
                                onDismiss()
                                action.onClick()
                            }
                        }
                    }
                    SheetCard { SheetButton("Cancel", colors.accent, bold = true, onClick = onDismiss) }
                }
            }
        }
    }
}

@Composable
private fun SheetCard(content: @Composable ColumnScope.() -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(Osho.colors.secondarySystemGroupedBackground)
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {},
        content = content,
    )
}

@Composable
private fun SheetButton(label: String, color: Color, bold: Boolean, onClick: () -> Unit) {
    Box(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 57.dp)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            fontSize = 20.sp,
            fontWeight = if (bold) FontWeight.SemiBold else FontWeight.Normal,
            color = color,
            textAlign = TextAlign.Center,
        )
    }
}

/**
 * List `.onDelete`: a full swipe left past half the row deletes it, over a red "Delete" well.
 * [shape] clips the well to the row's card corners.
 */
@Composable
internal fun SwipeToDelete(
    enabled: Boolean,
    shape: Shape,
    onDelete: () -> Unit,
    content: @Composable () -> Unit,
) {
    if (!enabled) {
        content()
        return
    }
    val state = rememberSwipeToDismissBoxState(positionalThreshold = { it * 0.5f })
    SwipeToDismissBox(
        state = state,
        enableDismissFromStartToEnd = false,
        onDismiss = { value -> if (value == SwipeToDismissBoxValue.EndToStart) onDelete() },
        modifier = Modifier.clip(shape),
        backgroundContent = {
            // Painted only mid-swipe; a resting red well bleeds through the anti-aliased corners.
            val swiping = state.dismissDirection == SwipeToDismissBoxValue.EndToStart
            Box(
                Modifier.fillMaxSize().background(if (swiping) Osho.colors.systemRed else Color.Transparent).padding(horizontal = 20.dp),
                contentAlignment = Alignment.CenterEnd,
            ) {
                if (swiping) Text("Delete", style = Osho.typography.body, color = Color.White)
            }
        },
    ) {
        content()
    }
}
