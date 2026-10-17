package com.agraabhi.oshodiscourses.core.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ArrowBackIosNew
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import dev.chrisbanes.haze.HazeState

/**
 * The Liquid Glass button surface. Sheets (elevated surfaces) have no backdrop to blur, so they
 * get a solid light fill; pages use [glass] over [hazeState], or its tint without one.
 */
@Composable
fun Modifier.glassButton(shape: Shape = CircleShape, hazeState: HazeState? = LocalHazeState.current): Modifier {
    val colors = Osho.colors
    val surface = shadow(6.dp, shape, ambientColor = colors.glassShadow, spotColor = colors.glassShadow)
    val filled = if (colors.elevated) {
        surface.background(if (colors.isDark) colors.tertiarySystemBackground else Color.White, shape).clip(shape)
    } else {
        surface.glass(shape, hazeState = hazeState)
    }
    return filled.border(0.5.dp, colors.glassBorder, shape)
}

/** iOS 26 toolbar button: a 44 dp Liquid Glass circle around one icon. */
@Composable
fun GlassIconButton(
    icon: ImageVector,
    contentDescription: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    tint: Color = Osho.colors.label,
    iconSize: Dp = 20.dp,
    hazeState: HazeState? = LocalHazeState.current,
) {
    Box(
        modifier = modifier
            .size(44.dp)
            .glassButton(CircleShape, hazeState)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { this.contentDescription = contentDescription },
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(iconSize))
    }
}

/** SF's back chevron is about 18 tall; Material's glyph fills three quarters of its box. */
private val BackChevronSize = 24.dp

/** The glass back circle of a pushed page or sheet sub-page. */
@Composable
fun BackGlassButton(onClick: () -> Unit, modifier: Modifier = Modifier, hazeState: HazeState? = LocalHazeState.current) {
    GlassIconButton(Icons.Rounded.ArrowBackIosNew, contentDescription = "Back", onClick = onClick, modifier = modifier, iconSize = BackChevronSize, hazeState = hazeState)
}

/**
 * Toolbar text button: a glass capsule with accent text, as iOS 26 draws "Done", "Cancel" and
 * "Save". [prominent] marks the confirmation action, which iOS sets semibold.
 */
@Composable
fun GlassTextButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    prominent: Boolean = false,
    bold: Boolean = false,
    enabled: Boolean = true,
    hazeState: HazeState? = LocalHazeState.current,
) {
    val colors = Osho.colors
    Box(
        modifier = modifier
            .heightIn(min = 44.dp)
            .widthIn(min = 44.dp)
            .alpha(if (enabled) 1f else DisabledAlpha)
            .glassButton(CircleShape, hazeState)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(horizontal = 16.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            style = Osho.typography.body,
            fontWeight = if (prominent || bold) FontWeight.SemiBold else FontWeight.Normal,
            color = colors.accent,
            maxLines = 1,
        )
    }
}

/**
 * A sheet's inline toolbar (ui-style.md §3.3): 56 high, centred 17/600 title, 44 dp glass
 * buttons. The title keeps clear of both slots so it stays centred whatever the buttons are.
 */
@Composable
fun SheetToolbar(
    title: String,
    modifier: Modifier = Modifier,
    leading: @Composable RowScope.() -> Unit = {},
    trailing: @Composable RowScope.() -> Unit = {},
) {
    Box(modifier.fillMaxWidth().heightIn(min = 56.dp).padding(horizontal = 16.dp, vertical = 6.dp)) {
        Row(Modifier.align(Alignment.CenterStart), verticalAlignment = Alignment.CenterVertically, content = leading)
        Text(
            title,
            style = Osho.typography.navInline,
            color = Osho.colors.label,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.Center,
            modifier = Modifier.align(Alignment.Center).padding(horizontal = 96.dp).semantics { heading() },
        )
        Row(Modifier.align(Alignment.CenterEnd), verticalAlignment = Alignment.CenterVertically, content = trailing)
    }
}

/** Inline navigation bar: back circle, centred 17/600 title, trailing slot. */
@Composable
fun InlineTopBar(
    title: String,
    onBack: (() -> Unit)?,
    modifier: Modifier = Modifier,
    trailing: @Composable BoxScope.() -> Unit = {},
) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = Grouped.barHeight)
            .padding(horizontal = 16.dp),
    ) {
        if (onBack != null) {
            BackGlassButton(onClick = onBack, modifier = Modifier.align(Alignment.CenterStart))
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

/** Liquid Glass toolbar shape for sheets: material tint, hairline border and a soft shadow (ui-style.md §1.7). */
@Composable
fun Modifier.toolbarGlass(shape: Shape): Modifier {
    val colors = Osho.colors
    return this
        .shadow(6.dp, shape, ambientColor = colors.glassShadow, spotColor = colors.glassShadow)
        .glass(shape)
        .background(if (colors.isDark) colors.tertiarySystemFill else Color.Transparent, shape)
        .border(0.5.dp, colors.glassBorder, shape)
}

/** Glass capsule grouping trailing toolbar buttons. */
@Composable
fun GlassCapsule(modifier: Modifier = Modifier, content: @Composable RowScope.() -> Unit) {
    Row(
        modifier = modifier.toolbarGlass(CircleShape),
        verticalAlignment = Alignment.CenterVertically,
        content = content,
    )
}

/** A 44 dp icon button with no ripple chrome, drawn at 35 % when disabled. */
@Composable
fun BarIconButton(
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
