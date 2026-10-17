package com.agraabhi.oshodiscourses.feature.transcript

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.agraabhi.oshodiscourses.core.ui.components.glass
import com.agraabhi.oshodiscourses.core.ui.components.toolbarGlass
import com.agraabhi.oshodiscourses.core.ui.theme.Osho

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

/** `m:ss`, or `h:mm:ss` from one hour; invalid or negative time shows `0:00`. */
internal fun formatTime(seconds: Double): String {
    if (!seconds.isFinite() || seconds < 0) return "0:00"
    val total = seconds.toLong()
    val h = total / 3600
    val m = (total % 3600) / 60
    val s = total % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
}
