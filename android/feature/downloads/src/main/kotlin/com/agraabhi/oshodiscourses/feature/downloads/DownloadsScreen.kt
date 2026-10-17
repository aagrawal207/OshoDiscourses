package com.agraabhi.oshodiscourses.feature.downloads

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation3.runtime.NavKey
import com.agraabhi.oshodiscourses.core.ui.LocalAppServices
import com.agraabhi.oshodiscourses.core.ui.components.PlaceholderScreen
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import kotlinx.serialization.Serializable

/** The Downloads tab's root. */
@Serializable
data object DownloadsRoute : NavKey

/** Bookmarks list; one tap deep in Downloads on a phone. */
@Serializable
data object BookmarksRoute : NavKey

/** My Activity dashboard; reached from Downloads and Settings. */
@Serializable
data object ListeningStatsRoute : NavKey

/** Downloads grouped by series, storage meter, stats and bookmarks (iOS `DownloadsView`). */
@Composable
fun DownloadsScreen(
    onOpenSeries: (seriesID: String) -> Unit,
    onOpenBookmarks: () -> Unit,
    onOpenListeningStats: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val services = LocalAppServices.current
    val downloaded by services.downloads.downloadedIDs.collectAsStateWithLifecycle()
    PlaceholderScreen(title = "Downloads", modifier = modifier) {
        Link("Bookmarks", onOpenBookmarks)
        Link("My Activity", onOpenListeningStats)
        services.catalog.allSeries
            .filter { s -> downloaded.any { it.startsWith("${s.id}-") } }
            .forEach { Link(it.name) { onOpenSeries(it.id) } }
    }
}

/** iOS `BookmarksView`. */
@Composable
fun BookmarksScreen(modifier: Modifier = Modifier) {
    PlaceholderScreen(title = "Bookmarks", modifier = modifier)
}

/** iOS `ListeningStatsView`. */
@Composable
fun ListeningStatsScreen(modifier: Modifier = Modifier) {
    PlaceholderScreen(title = "My Activity", modifier = modifier)
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
