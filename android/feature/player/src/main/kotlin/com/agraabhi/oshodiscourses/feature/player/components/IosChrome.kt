package com.agraabhi.oshodiscourses.feature.player.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ArrowBackIosNew
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
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

/**
 * Inline navigation bar (ui-style.md §3.3): 44 high, centred 17/600 title, 44 dp glass buttons.
 * The side slots share a width so the title stays centred whatever the buttons are.
 */
@Composable
internal fun InlineTopBar(
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

/** The Liquid Glass button surface. Sheets have no backdrop to blur, so it is a light tint. */
@Composable
private fun Modifier.glassButton(): Modifier {
    val colors = Osho.colors
    val fill = if (colors.isDark) colors.tertiarySystemBackground else Color.White
    return shadow(6.dp, CircleShape, ambientColor = colors.glassShadow, spotColor = colors.glassShadow)
        .background(fill, CircleShape)
        .border(0.5.dp, colors.glassBorder, CircleShape)
        .clip(CircleShape)
}

@Composable
internal fun GlassIconButton(
    icon: ImageVector,
    contentDescription: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    iconSize: Dp = 20.dp,
) {
    Box(
        modifier = modifier
            .size(44.dp)
            .glassButton()
            .clickable(role = Role.Button, onClickLabel = null, onClick = onClick)
            .semantics { this.contentDescription = contentDescription },
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = Osho.colors.label, modifier = Modifier.size(iconSize))
    }
}

@Composable
internal fun BackGlassButton(onClick: () -> Unit, modifier: Modifier = Modifier) {
    GlassIconButton(Icons.Rounded.ArrowBackIosNew, contentDescription = "Back", onClick = onClick, modifier = modifier, iconSize = 20.dp)
}

/**
 * Toolbar text button. [prominent] is the iOS 26 confirmation style ("Done", "Save"): an accent
 * capsule with white text; the plain style is a glass capsule.
 */
@Composable
internal fun GlassTextButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    prominent: Boolean = false,
    enabled: Boolean = true,
) {
    val colors = Osho.colors
    val surface = if (prominent) {
        Modifier
            .shadow(6.dp, CircleShape, ambientColor = colors.glassShadow, spotColor = colors.glassShadow)
            .background(colors.accent, CircleShape)
            .clip(CircleShape)
    } else {
        Modifier.glassButton()
    }
    Box(
        modifier = modifier
            .heightIn(min = 44.dp)
            .widthIn(min = 44.dp)
            .alpha(if (enabled) 1f else DisabledAlpha)
            .then(surface)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(horizontal = 16.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            style = Osho.typography.body,
            fontWeight = if (prominent) FontWeight.SemiBold else FontWeight.Normal,
            color = if (prominent) colors.onAccent else colors.label,
            maxLines = 1,
        )
    }
}

/**
 * An inset-grouped Form section (ui-style.md §3.3, §8): 17/600 secondary header, r 22 card
 * inset 16, 13 sp secondary footer. Headers are never uppercased.
 */
@Composable
internal fun GroupedSection(
    modifier: Modifier = Modifier,
    header: String? = null,
    footer: (@Composable ColumnScope.() -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    val colors = Osho.colors
    Column(modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
        if (header != null) {
            Text(
                header,
                style = Osho.typography.listHeader,
                color = colors.secondaryLabel,
                modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 6.dp).semantics { heading() },
            )
        }
        Column(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(22.dp))
                .background(colors.secondarySystemGroupedBackground),
            content = content,
        )
        if (footer != null) {
            Column(
                Modifier.padding(start = 16.dp, end = 16.dp, top = 7.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
                content = footer,
            )
        }
    }
}

@Composable
internal fun SectionFooterText(text: String, color: Color = Osho.colors.secondaryLabel) {
    Text(text, style = Osho.typography.listFooter, color = color)
}

/** Row separator inset to the text start, as UIKit draws it. */
@Composable
internal fun GroupedDivider(startInset: Dp = 16.dp) {
    HorizontalDivider(Modifier.padding(start = startInset), thickness = Dp.Hairline, color = Osho.colors.separator)
}

/** The bold, small disclosure chevron at the end of a navigation row. */
@Composable
internal fun DisclosureChevron() {
    Icon(
        Icons.Rounded.ChevronRight,
        contentDescription = null,
        tint = Osho.colors.tertiaryLabel,
        modifier = Modifier.size(22.dp),
    )
}

/** Gap between grouped sections. */
internal val SectionSpacing = 24.dp

@Composable
internal fun SectionGap() {
    Box(Modifier.height(SectionSpacing))
}
