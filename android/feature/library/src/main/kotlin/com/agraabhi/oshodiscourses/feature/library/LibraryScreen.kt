package com.agraabhi.oshodiscourses.feature.library

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.navigation3.runtime.NavKey
import com.agraabhi.oshodiscourses.core.ui.LocalAppServices
import com.agraabhi.oshodiscourses.core.ui.components.PlaceholderScreen
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import kotlinx.serialization.Serializable

/** The Library tab's root. */
@Serializable
data object LibraryRoute : NavKey

/** Every series with search, filter chips and sort (iOS `LibraryView`). */
@Composable
fun LibraryScreen(
    onOpenSeries: (seriesID: String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val catalog = LocalAppServices.current.catalog
    PlaceholderScreen(title = "Library", modifier = modifier) {
        catalog.allSeries.forEach {
            Text(
                it.name,
                style = Osho.typography.body,
                color = Osho.colors.label,
                modifier = Modifier.clickable { onOpenSeries(it.id) }.padding(vertical = 8.dp),
            )
        }
    }
}
