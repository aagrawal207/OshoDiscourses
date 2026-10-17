package com.agraabhi.oshodiscourses.feature.transcript

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.rounded.Replay
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MenuDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.agraabhi.oshodiscourses.core.ui.components.glass
import com.agraabhi.oshodiscourses.core.ui.theme.Osho

/** iOS caps the transcript bars at Dynamic Type xxxLarge so they stay on one line. */
@Composable
internal fun CappedFontScale(content: @Composable () -> Unit) {
    val density = LocalDensity.current
    CompositionLocalProvider(
        LocalDensity provides Density(density.density, density.fontScale.coerceAtMost(1.35f)),
        content = content,
    )
}

/** Liquid Glass toolbar shape: material tint, hairline border and a soft shadow (ui-style.md §1.7). */
@Composable
internal fun Modifier.toolbarGlass(shape: androidx.compose.ui.graphics.Shape): Modifier {
    val colors = Osho.colors
    return this
        .shadow(6.dp, shape, ambientColor = colors.glassShadow, spotColor = colors.glassShadow)
        .glass(shape)
        .background(if (colors.isDark) colors.tertiarySystemFill else Color.Transparent, shape)
        .border(0.5.dp, colors.glassBorder, shape)
}

/** 44 dp glass circle with an icon, the iOS 26 toolbar button. */
@Composable
internal fun GlassCircleButton(icon: ImageVector, label: String, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .size(44.dp)
            .toolbarGlass(CircleShape)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = Osho.colors.label, modifier = Modifier.size(22.dp))
    }
}

/** Glass capsule grouping trailing toolbar buttons. */
@Composable
internal fun GlassCapsule(modifier: Modifier = Modifier, content: @Composable RowScope.() -> Unit) {
    Row(
        modifier = modifier.toolbarGlass(CircleShape),
        verticalAlignment = Alignment.CenterVertically,
        content = content,
    )
}

/** A 44 dp icon button with no ripple chrome, drawn at 35 % when disabled. */
@Composable
internal fun BarIconButton(
    icon: ImageVector,
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    tint: Color = Osho.colors.label,
    iconSize: Dp = 22.dp,
    content: (@Composable () -> Unit)? = null,
) {
    Box(
        modifier = modifier
            .size(44.dp)
            .clip(CircleShape)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = label }
            .alpha(if (enabled) 1f else 0.35f),
        contentAlignment = Alignment.Center,
    ) {
        if (content != null) content() else Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(iconSize))
    }
}

/** `gobackward.15`: Material has no replay-15, so "15" is drawn inside `replay`. */
@Composable
internal fun ReplayFifteenIcon(tint: Color, size: Dp = 24.dp, modifier: Modifier = Modifier) {
    Box(modifier.size(size), contentAlignment = Alignment.Center) {
        Icon(Icons.Rounded.Replay, contentDescription = null, tint = tint, modifier = Modifier.size(size))
        val scale = size.value / 24f
        Text(
            "15",
            color = tint,
            fontSize = with(LocalDensity.current) { (8 * scale).dp.toSp() },
            fontWeight = FontWeight.Bold,
            modifier = Modifier.offset(y = (1 * scale).dp),
        )
    }
}

/** The 36 × 5 sheet handle (secondary @ 50 %). */
@Composable
internal fun SheetHandle(modifier: Modifier = Modifier) {
    Box(
        modifier
            .padding(top = 5.dp, bottom = 2.dp)
            .size(width = 36.dp, height = 5.dp)
            .clip(CircleShape)
            .background(Osho.colors.secondaryLabel.copy(alpha = 0.5f)),
    )
}

/** `ContentUnavailableView`: icon 48, title 22 bold, description 15 secondary, max width 320. */
@Composable
internal fun EmptyState(
    title: String,
    description: String,
    modifier: Modifier = Modifier,
    icon: ImageVector = Icons.Outlined.Description,
    actions: @Composable () -> Unit = {},
) {
    Column(
        modifier = modifier.widthIn(max = 320.dp).padding(horizontal = 16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(icon, contentDescription = null, tint = Osho.colors.secondaryLabel, modifier = Modifier.size(48.dp))
        Text(title, style = Osho.typography.title2, fontWeight = FontWeight.Bold, color = Osho.colors.label, textAlign = TextAlign.Center)
        Text(description, style = Osho.typography.subheadline, color = Osho.colors.secondaryLabel, textAlign = TextAlign.Center)
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) { actions() }
    }
}

/** Capsule toast on `.ultraThinMaterial`. */
@Composable
internal fun ToastCapsule(text: String, modifier: Modifier = Modifier) {
    Text(
        text,
        style = Osho.typography.subheadline,
        fontWeight = FontWeight.Medium,
        color = Osho.colors.label,
        modifier = modifier
            .toolbarGlass(CircleShape)
            .padding(horizontal = 16.dp, vertical = 10.dp),
    )
}

/** iOS-styled menu: rounded card on the grouped row colour, 17 sp items. */
@Composable
internal fun OshoMenu(
    expanded: Boolean,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
    offset: DpOffset = DpOffset(0.dp, 0.dp),
    content: @Composable () -> Unit,
) {
    DropdownMenu(
        expanded = expanded,
        onDismissRequest = onDismiss,
        modifier = modifier.widthIn(min = 220.dp, max = 280.dp),
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

@Composable
internal fun OshoMenuItem(
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

@Composable
internal fun OshoMenuHeader(text: String) {
    Text(
        text,
        style = Osho.typography.footnote,
        color = Osho.colors.secondaryLabel,
        modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 4.dp),
    )
}

@Composable
internal fun OshoMenuNote(text: String) {
    Text(
        text,
        style = Osho.typography.footnote,
        color = Osho.colors.secondaryLabel,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
    )
}

@Composable
internal fun OshoMenuDivider() {
    HorizontalDivider(Modifier.padding(vertical = 4.dp), thickness = 6.dp, color = Osho.colors.tertiarySystemFill)
}

/** `m:ss`, or `h:mm:ss` from one hour; invalid or negative time shows `0:00`. */
internal fun formatTime(seconds: Double): String {
    if (!seconds.isFinite() || seconds < 0) return "0:00"
    val total = seconds.toLong()
    val h = total / 3600
    val m = (total % 3600) / 60
    val s = total % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
}
