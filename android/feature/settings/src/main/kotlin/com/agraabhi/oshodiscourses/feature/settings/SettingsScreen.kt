package com.agraabhi.oshodiscourses.feature.settings

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
import com.agraabhi.oshodiscourses.core.model.Appearance
import com.agraabhi.oshodiscourses.core.ui.LocalAppServices
import com.agraabhi.oshodiscourses.core.ui.components.PlaceholderScreen
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable

/** The Settings tab's root. */
@Serializable
data object SettingsRoute : NavKey

/** Language, player and download prefs, DeNoise, appearance and About (iOS `SettingsView`). */
@Composable
fun SettingsScreen(
    onOpenDenoise: () -> Unit,
    onOpenListeningStats: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val settings = LocalAppServices.current.settings
    val current by settings.settings.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    PlaceholderScreen(title = "Settings", modifier = modifier) {
        Link("DeNoise", onOpenDenoise)
        Link("My Activity", onOpenListeningStats)
        Appearance.entries.forEach { appearance ->
            val marker = if (current.appearance == appearance) "● " else "○ "
            Link(marker + appearance.rawValue.replaceFirstChar { it.uppercase() }) {
                scope.launch { settings.setAppearance(appearance) }
            }
        }
    }
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
