package com.agraabhi.oshodiscourses.feature.series

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.navigation3.runtime.NavKey
import com.agraabhi.oshodiscourses.core.domain.player.PlayResult
import com.agraabhi.oshodiscourses.core.ui.LocalAppServices
import com.agraabhi.oshodiscourses.core.ui.components.PlaceholderScreen
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable

/** A series page, pushed onto whichever tab opened it (Home, Library or Downloads). */
@Serializable
data class SeriesRoute(val seriesID: String) : NavKey

/** Hero header, discourse list, download and play actions (iOS `SeriesDetailView`). */
@Composable
fun SeriesScreen(
    seriesID: String,
    onOpenPlayer: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val services = LocalAppServices.current
    val scope = rememberCoroutineScope()
    val series = services.catalog.series(seriesID)
    PlaceholderScreen(title = series?.name ?: "Series", modifier = modifier) {
        series?.let { services.catalog.discourses(it) }.orEmpty().forEach { discourse ->
            Text(
                discourse.displayTitle,
                style = Osho.typography.body,
                color = Osho.colors.label,
                modifier = Modifier
                    .clickable {
                        scope.launch {
                            services.downloads.enqueue(discourse.id)
                            if (services.player.play(discourse.id) == PlayResult.Started) onOpenPlayer()
                        }
                    }
                    .padding(vertical = 8.dp),
            )
        }
    }
}
