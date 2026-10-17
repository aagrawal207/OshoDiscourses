package com.agraabhi.oshodiscourses.feature.transcript

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.dp
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import androidx.compose.ui.Modifier
import androidx.navigation3.runtime.NavKey
import com.agraabhi.oshodiscourses.core.ui.LocalAppServices
import com.agraabhi.oshodiscourses.core.ui.components.PlaceholderScreen
import kotlinx.serialization.Serializable

/** The transcript reader for one discourse, presented as a sheet over the player. */
@Serializable
data class TranscriptRoute(val discourseID: String) : NavKey

/** Lyrics-style reader with highlight, auto-follow, anchors and search (iOS `TranscriptView`). */
@Composable
fun TranscriptScreen(
    discourseID: String,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val title = LocalAppServices.current.catalog.entry(discourseID)?.discourse?.displayTitle ?: "Transcript"
    PlaceholderScreen(title = title, modifier = modifier, message = "Transcript") {
        Text("Close", style = Osho.typography.body, color = Osho.colors.accent, modifier = Modifier.clickable(onClick = onDismiss).padding(vertical = 8.dp))
    }
}
