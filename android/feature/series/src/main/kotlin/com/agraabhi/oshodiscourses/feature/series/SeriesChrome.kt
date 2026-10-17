package com.agraabhi.oshodiscourses.feature.series

import android.view.Gravity
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MenuDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalView
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ArrowBackIosNew
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.DialogWindowProvider
import com.agraabhi.oshodiscourses.core.ui.components.glass
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import com.agraabhi.oshodiscourses.core.ui.theme.ProvideElevatedSurfaces

/** iOS 26 toolbar button: a 44 dp Liquid Glass circle around one icon. */
@Composable
internal fun GlassIconButton(
    icon: ImageVector,
    contentDescription: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    tint: Color = Osho.colors.label,
    iconSize: Int = 20,
) {
    val colors = Osho.colors
    Box(
        modifier = modifier
            .size(44.dp)
            .shadow(6.dp, CircleShape, ambientColor = colors.glassShadow, spotColor = colors.glassShadow)
            .glass(CircleShape)
            .border(0.5.dp, colors.glassBorder, CircleShape)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { this.contentDescription = contentDescription },
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(iconSize.dp))
    }
}

/** Inline navigation bar: back circle, centred 17/600 title, trailing slot. */
@Composable
internal fun InlineTopBar(
    title: String,
    onBack: (() -> Unit)?,
    modifier: Modifier = Modifier,
    trailing: @Composable BoxScope.() -> Unit = {},
) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp)
            .padding(horizontal = 16.dp, vertical = 4.dp),
    ) {
        if (onBack != null) {
            GlassIconButton(
                icon = Icons.Rounded.ArrowBackIosNew,
                contentDescription = "Back",
                onClick = onBack,
                modifier = Modifier.align(Alignment.CenterStart),
            )
        }
        Box(Modifier.align(Alignment.Center).padding(horizontal = 56.dp)) {
            CappedFontScale {
                Text(
                    text = title,
                    style = Osho.typography.navInline,
                    color = Osho.colors.label,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.semantics { heading() },
                )
            }
        }
        Box(Modifier.align(Alignment.CenterEnd), content = trailing)
    }
}

/** One iOS menu row; destructive rows are red. */
data class MenuAction(
    val label: String,
    val icon: ImageVector,
    val destructive: Boolean = false,
    /** Draws a divider above this row, as iOS does before a destructive group. */
    val dividerBefore: Boolean = false,
    val onClick: () -> Unit,
)

/** Material's DropdownMenu restyled as an iOS menu (ui-style.md §8): r 16, elevated card, 17 sp rows. */
@Composable
internal fun OshoMenu(
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
                    leadingIcon = { Icon(action.icon, contentDescription = null, tint = tint, modifier = Modifier.size(20.dp)) },
                    onClick = {
                        onDismiss()
                        action.onClick()
                    },
                    colors = MenuDefaults.itemColors(),
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp, vertical = 4.dp),
                )
            }
        }
    }
}

/** iOS `confirmationDialog` as an iPhone action sheet: a title-and-actions card above a Cancel card. */
@Composable
internal fun ActionSheet(
    title: String,
    message: String,
    actionLabel: String,
    onAction: () -> Unit,
    onDismiss: () -> Unit,
) {
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        val window = (LocalView.current.parent as? DialogWindowProvider)?.window
        SideEffect { window?.setGravity(Gravity.BOTTOM) }
        ProvideElevatedSurfaces {
            val colors = Osho.colors
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .navigationBarsPadding()
                    .padding(horizontal = 8.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                SheetCard {
                    Column(
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp),
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
                        Text(message, style = Osho.typography.footnote, color = colors.secondaryLabel, textAlign = TextAlign.Center)
                    }
                    HorizontalDivider(thickness = 0.5.dp, color = colors.separator)
                    SheetButton(actionLabel, bold = false) {
                        onDismiss()
                        onAction()
                    }
                }
                SheetCard { SheetButton("Cancel", bold = true, onClick = onDismiss) }
            }
        }
    }
}

@Composable
private fun SheetCard(content: @Composable ColumnScope.() -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .background(Osho.colors.secondarySystemGroupedBackground, RoundedCornerShape(14.dp)),
        content = content,
    )
}

@Composable
private fun SheetButton(label: String, bold: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 57.dp)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 8.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            fontSize = 20.sp,
            fontWeight = if (bold) FontWeight.SemiBold else FontWeight.Normal,
            color = Osho.colors.accent,
            textAlign = TextAlign.Center,
        )
    }
}

/** Keeps a row of text icons apart like SwiftUI's `Label` (icon, 6 dp, title). */
@Composable
internal fun LabelRow(icon: ImageVector, iconSize: Dp, tint: Color, content: @Composable () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(iconSize))
        Spacer(Modifier.width(6.dp))
        content()
    }
}

/** iOS bars cap Dynamic Type at xxxLarge (about 1.35x) so they keep one line. */
@Composable
internal fun CappedFontScale(max: Float = 1.35f, content: @Composable () -> Unit) {
    val density = LocalDensity.current
    CompositionLocalProvider(LocalDensity provides Density(density.density, density.fontScale.coerceAtMost(max)), content = content)
}
