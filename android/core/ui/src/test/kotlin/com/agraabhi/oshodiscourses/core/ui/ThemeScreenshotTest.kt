package com.agraabhi.oshodiscourses.core.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.agraabhi.oshodiscourses.core.model.AccentTheme
import com.agraabhi.oshodiscourses.core.model.Appearance
import com.agraabhi.oshodiscourses.core.ui.components.FilterChipStyle
import com.agraabhi.oshodiscourses.core.ui.components.OshoFilterChip
import com.agraabhi.oshodiscourses.core.ui.components.OshoTabBar
import com.agraabhi.oshodiscourses.core.ui.components.OshoTabItem
import com.agraabhi.oshodiscourses.core.ui.components.SectionHeader
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.LibraryBooks
import androidx.compose.material.icons.rounded.ArrowCircleDown
import androidx.compose.material.icons.rounded.Home
import androidx.compose.material.icons.rounded.Settings
import com.agraabhi.oshodiscourses.core.ui.components.SeriesThumbnail
import com.agraabhi.oshodiscourses.core.ui.theme.AccentPalette
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import com.agraabhi.oshodiscourses.core.ui.theme.OshoTheme
import com.github.takahirom.roborazzi.captureRoboImage
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], qualifiers = "w393dp-h852dp-xxhdpi")
class ThemeScreenshotTest {
    @get:Rule
    val compose = createComposeRule()

    private fun capture(appearance: Appearance, name: String) {
        compose.setContent {
            OshoTheme(appearance = appearance, accent = AccentTheme.PURPLE) {
                Column(
                    Modifier.background(Osho.colors.systemBackground).padding(vertical = 16.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    SectionHeader("Popular", Modifier.padding(horizontal = 16.dp), actionLabel = "Clear", onAction = {})
                    Row(Modifier.padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        SeriesThumbnail("A Bird on the Wing", 56.dp)
                        SeriesThumbnail("Ashtavakra Maha Geeta", 56.dp)
                        SeriesThumbnail("The Mustard Seed", 56.dp)
                    }
                    Row(Modifier.padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        OshoFilterChip("All", selected = true, onClick = {})
                        OshoFilterChip("Funny", selected = false, onClick = {})
                        OshoFilterChip("Hindi", selected = false, onClick = {}, style = FilterChipStyle.COMPACT)
                    }
                    OshoTabBar(
                        items = listOf(
                            OshoTabItem("Home", Icons.Rounded.Home),
                            OshoTabItem("Library", Icons.AutoMirrored.Rounded.LibraryBooks),
                            OshoTabItem("Downloads", Icons.Rounded.ArrowCircleDown),
                            OshoTabItem("Settings", Icons.Rounded.Settings),
                        ),
                        selectedIndex = 0,
                        onSelect = {},
                    )
                    Row(Modifier.padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        AccentTheme.entries.forEach {
                            Text(
                                it.displayName.take(2),
                                color = Osho.colors.onAccent,
                                modifier = Modifier.background(AccentPalette.color(it, Osho.colors.isDark)).padding(6.dp),
                            )
                        }
                    }
                }
            }
        }
        compose.onRoot().captureRoboImage("src/test/screenshots/$name.png")
    }

    @Test
    fun componentsLight() = capture(Appearance.LIGHT, "core_ui_components_light")

    @Test
    fun componentsDark() = capture(Appearance.DARK, "core_ui_components_dark")
}
