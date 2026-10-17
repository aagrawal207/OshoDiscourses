package com.agraabhi.oshodiscourses.feature.player

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation3.runtime.NavKey
import com.agraabhi.oshodiscourses.core.ui.LocalAppServices
import com.agraabhi.oshodiscourses.core.ui.components.PlaceholderScreen
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable

/** The shared DeNoise screen, pushed from Settings or opened from the player. */
@Serializable
data object DenoiseRoute : NavKey

/**
 * The full player, modal over the tabs (iOS `PlayerView` sheet). [onOpenSeries] closes it and
 * pushes the series on Home, as iOS does from the series title.
 */
@Composable
fun PlayerScreen(
    onDismiss: () -> Unit,
    onOpenTranscript: (discourseID: String) -> Unit,
    onOpenSeries: (seriesID: String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val services = LocalAppServices.current
    val player = services.player
    val state by player.state.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    PlaceholderScreen(title = state.currentTitle.ifEmpty { "Not Playing" }, modifier = modifier, message = state.currentSeries) {
        Link(if (state.isPlaying) "Pause" else "Play") { scope.launch { player.togglePlayPause() } }
        state.currentTrackId?.let { id ->
            Link("Transcript") { onOpenTranscript(id) }
            services.catalog.entry(id)?.series?.let { series -> Link(series.name) { onOpenSeries(series.id) } }
        }
        Link("Close", onDismiss)
    }
}

/** iOS `AudioEnhancementView`. */
@Composable
fun DenoiseScreen(modifier: Modifier = Modifier) {
    PlaceholderScreen(title = "DeNoise", modifier = modifier)
}

@Composable
private fun Link(label: String, onClick: () -> Unit) {
    Text(
        label,
        style = Osho.typography.body,
        color = Osho.colors.accent,
        modifier = Modifier.clickable(onClick = onClick).padding(vertical = 8.dp),
    )
}
