package com.agraabhi.oshodiscourses.feature.player

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.ripple
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.agraabhi.oshodiscourses.core.ui.components.glass
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import com.agraabhi.oshodiscourses.feature.player.components.PortraitArtwork

/**
 * The floating bar above the tab bar (iOS `MiniPlayerView`, ui-style.md §6.5). The host shows it
 * only while a discourse is loaded and turns [onHeightChanged] into `LocalMiniPlayerClearance`.
 */
@Composable
fun MiniPlayer(
    onOpenPlayer: () -> Unit,
    modifier: Modifier = Modifier,
    onHeightChanged: (Dp) -> Unit = {},
) {
    val viewModel = playerViewModel()
    val ui by viewModel.state.collectAsStateWithLifecycle()
    MiniPlayerContent(
        ui = ui,
        onOpenPlayer = onOpenPlayer,
        onTogglePlayPause = viewModel::togglePlayPause,
        modifier = modifier,
        onHeightChanged = onHeightChanged,
    )
}

@Composable
internal fun MiniPlayerContent(
    ui: PlayerUiState,
    onOpenPlayer: () -> Unit,
    onTogglePlayPause: () -> Unit,
    modifier: Modifier = Modifier,
    onHeightChanged: (Dp) -> Unit = {},
) {
    val colors = Osho.colors
    val density = LocalDensity.current
    val player = ui.player
    val shape = RoundedCornerShape(14.dp)
    val discourseLine = PlayerFormatting.discourseLine(player.currentTitle, player.currentSeries)
    val seriesLine = PlayerFormatting.seriesLine(player.currentTitle, player.currentSeries)
    val playPauseLabel = if (player.isPlaying) "Pause" else "Play"

    Box(modifier.fillMaxWidth().padding(horizontal = 8.dp), contentAlignment = Alignment.Center) {
        Column(
            modifier = Modifier
                .widthIn(max = 640.dp)
                .fillMaxWidth()
                .onSizeChanged { onHeightChanged(with(density) { it.height.toDp() }) }
                .shadow(8.dp, shape, ambientColor = Color.Black.copy(alpha = 0.3f), spotColor = Color.Black.copy(alpha = 0.3f))
                .glass(shape)
                .clickable(onClick = onOpenPlayer)
                .clearAndSetSemantics {
                    contentDescription = listOfNotNull(discourseLine, seriesLine).joinToString(", ")
                    stateDescription = if (player.isPlaying) "Playing" else "Paused"
                    role = Role.Button
                    onClick(label = "open the full player") { onOpenPlayer(); true }
                    customActions = listOf(CustomAccessibilityAction(playPauseLabel) { onTogglePlayPause(); true })
                },
        ) {
            Box(Modifier.fillMaxWidth().height(2.5.dp).background(colors.label.copy(alpha = 0.08f))) {
                Box(Modifier.fillMaxWidth(ui.progress).height(2.5.dp).background(colors.accent))
            }
            Row(
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                PortraitArtwork(size = 44.dp, cornerRadius = 6.dp)
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(
                        discourseLine ?: seriesLine,
                        style = Osho.typography.subheadline,
                        fontWeight = FontWeight.SemiBold,
                        color = colors.label,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    if (discourseLine != null) {
                        Text(
                            seriesLine,
                            style = Osho.typography.caption,
                            color = colors.secondaryLabel,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
                Box(
                    Modifier
                        .size(44.dp)
                        .clickable(
                            interactionSource = remember { MutableInteractionSource() },
                            indication = ripple(bounded = false, radius = 22.dp),
                            role = Role.Button,
                            onClick = onTogglePlayPause,
                        ),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        if (player.isPlaying) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                        contentDescription = playPauseLabel,
                        tint = colors.accent,
                        modifier = Modifier.size(26.dp),
                    )
                }
            }
        }
    }
}
