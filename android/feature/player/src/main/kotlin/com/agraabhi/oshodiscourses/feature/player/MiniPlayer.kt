package com.agraabhi.oshodiscourses.feature.player

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.agraabhi.oshodiscourses.core.ui.LocalAppServices
import com.agraabhi.oshodiscourses.core.ui.components.SeriesThumbnail
import com.agraabhi.oshodiscourses.core.ui.components.glass
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import kotlinx.coroutines.launch

/**
 * The floating bar above the tab bar (iOS `MiniPlayerView`, ui-style.md §6.5). The host shows
 * it only while a discourse is loaded and measures it to size `LocalMiniPlayerClearance`.
 */
@Composable
fun MiniPlayer(
    onOpenPlayer: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val player = LocalAppServices.current.player
    val state by player.state.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    val shape = RoundedCornerShape(14.dp)
    val progress = if (state.duration > 0) (state.currentTime / state.duration).toFloat().coerceIn(0f, 1f) else 0f
    Column(
        modifier = modifier
            .padding(horizontal = 8.dp)
            .widthIn(max = 640.dp)
            .fillMaxWidth()
            .shadow(8.dp, shape, ambientColor = Color.Black.copy(alpha = 0.3f), spotColor = Color.Black.copy(alpha = 0.3f))
            .glass(shape)
            .clickable(onClick = onOpenPlayer),
    ) {
        Box(Modifier.fillMaxWidth().height(2.5.dp).background(Osho.colors.label.copy(alpha = 0.08f))) {
            Box(Modifier.fillMaxWidth(progress).height(2.5.dp).background(Osho.colors.accent))
        }
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            SeriesThumbnail(state.currentSeries, 44.dp)
            Column(Modifier.weight(1f)) {
                val number = state.currentTitle.substringAfterLast('#', "").takeIf { it.isNotEmpty() && it.all(Char::isDigit) }
                Text(
                    if (number != null) "Discourse $number" else state.currentSeries.ifEmpty { state.currentTitle },
                    style = Osho.typography.subheadline,
                    fontWeight = FontWeight.SemiBold,
                    color = Osho.colors.label,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (number != null) {
                    Text(state.currentSeries, style = Osho.typography.caption, color = Osho.colors.secondaryLabel, maxLines = 1)
                }
            }
            IconButton(onClick = { scope.launch { player.togglePlayPause() } }, modifier = Modifier.size(44.dp)) {
                Icon(
                    if (state.isPlaying) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                    contentDescription = if (state.isPlaying) "Pause" else "Play",
                    tint = Osho.colors.accent,
                )
            }
        }
    }
}
