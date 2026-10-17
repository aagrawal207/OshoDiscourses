package com.agraabhi.oshodiscourses.core.ui

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.LibraryBooks
import androidx.compose.material.icons.rounded.ArrowCircleDown
import androidx.compose.material.icons.rounded.Home
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.Density
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.agraabhi.oshodiscourses.core.model.AccentTheme
import com.agraabhi.oshodiscourses.core.model.Appearance
import com.agraabhi.oshodiscourses.core.ui.components.OshoTabBar
import com.agraabhi.oshodiscourses.core.ui.components.OshoTabItem
import com.agraabhi.oshodiscourses.core.ui.theme.OshoTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [36], qualifiers = "w393dp-h852dp-xxhdpi")
class OshoTabBarFontScaleTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun labelsKeepTheirSizeAtLargeFontScale() {
        compose.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, fontScale = 2f)) {
                OshoTheme(appearance = Appearance.LIGHT, accent = AccentTheme.PURPLE) {
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
                }
            }
        }

        val layouts = mutableListOf<TextLayoutResult>()
        compose.onNodeWithText("Downloads").fetchSemanticsNode().config[SemanticsActions.GetTextLayoutResult].action!!(layouts)
        val layout = layouts.single()
        // One line only, so a label too wide for its item wraps and loses its tail.
        assertFalse("Downloads is cut off", layout.multiParagraph.didExceedMaxLines)
        assertEquals(1f, layout.layoutInput.density.fontScale)
    }
}
