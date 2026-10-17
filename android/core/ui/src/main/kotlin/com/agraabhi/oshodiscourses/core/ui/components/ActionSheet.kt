package com.agraabhi.oshodiscourses.core.ui.components

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
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.rounded.Cancel
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import com.agraabhi.oshodiscourses.core.ui.theme.ProvideElevatedSurfaces

/** One button in an [ActionSheet]; destructive buttons are red. */
data class SheetAction(val label: String, val destructive: Boolean = false, val onClick: () -> Unit)

/**
 * iPhone `confirmationDialog` with a visible title: a bottom card of actions and a separate
 * Cancel card (ui-style.md §8).
 */
@Composable
fun ActionSheet(
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

/** The one-action form, with the action in the accent colour. */
@Composable
fun ActionSheet(
    title: String,
    message: String,
    actionLabel: String,
    onAction: () -> Unit,
    onDismiss: () -> Unit,
) = ActionSheet(title, message, listOf(SheetAction(actionLabel, onClick = onAction)), onDismiss)
