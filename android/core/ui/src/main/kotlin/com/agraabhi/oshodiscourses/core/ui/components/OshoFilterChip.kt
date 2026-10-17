package com.agraabhi.oshodiscourses.core.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.agraabhi.oshodiscourses.core.ui.theme.Osho

/** [REGULAR] is the Bookmarks chip; [COMPACT] is the smaller Library filter chip. */
enum class FilterChipStyle { REGULAR, COMPACT }

/**
 * iOS capsule filter chip: accent fill with white text when active, tertiary system fill
 * otherwise. Not Material's outlined chip, which reads very differently.
 */
@Composable
fun OshoFilterChip(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    style: FilterChipStyle = FilterChipStyle.REGULAR,
) {
    val colors = Osho.colors
    val typography = Osho.typography
    val textStyle = if (style == FilterChipStyle.REGULAR) typography.subheadline else typography.caption
    val inactiveText = if (style == FilterChipStyle.REGULAR) colors.label else colors.secondaryLabel
    val content = if (selected) colors.onAccent else inactiveText
    Row(
        modifier = modifier
            .clip(CircleShape)
            .background(if (selected) colors.accent else colors.tertiarySystemFill)
            .clickable(role = Role.Tab, onClick = onClick)
            .semantics { this.selected = selected }
            .padding(horizontal = 12.dp, vertical = if (style == FilterChipStyle.REGULAR) 7.dp else 6.dp),
        horizontalArrangement = Arrangement.spacedBy(5.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) {
            Icon(icon, contentDescription = null, tint = content, modifier = Modifier.size(12.dp))
        }
        Text(label, style = textStyle, fontWeight = FontWeight.Medium, color = content)
    }
}
