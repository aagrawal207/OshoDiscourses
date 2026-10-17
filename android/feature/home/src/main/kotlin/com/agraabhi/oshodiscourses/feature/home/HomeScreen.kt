package com.agraabhi.oshodiscourses.feature.home

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.navigation3.runtime.NavKey
import com.agraabhi.oshodiscourses.core.model.SeriesInfo
import com.agraabhi.oshodiscourses.core.ui.LocalAppServices
import com.agraabhi.oshodiscourses.core.ui.components.PlaceholderScreen
import com.agraabhi.oshodiscourses.core.ui.components.SectionHeader
import com.agraabhi.oshodiscourses.core.ui.components.SeriesThumbnail
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import kotlinx.serialization.Serializable

/** The Home tab's root. */
@Serializable
data object HomeRoute : NavKey

/**
 * Home: Continue Listening, Recently Completed and the curated sections (iOS `HomeView`).
 * [onOpenSeries] pushes the series page onto the Home stack.
 */
@Composable
fun HomeScreen(
    onOpenSeries: (seriesID: String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val catalog = LocalAppServices.current.catalog
    PlaceholderScreen(title = "Home", modifier = modifier) {
        SectionHeader("Popular")
        catalog.allSeries.forEach { SeriesRow(it, onClick = { onOpenSeries(it.id) }) }
    }
}

@Composable
private fun SeriesRow(series: SeriesInfo, onClick: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        SeriesThumbnail(series.name, 56.dp)
        Text(series.name, style = Osho.typography.subheadline, color = Osho.colors.label)
    }
}
