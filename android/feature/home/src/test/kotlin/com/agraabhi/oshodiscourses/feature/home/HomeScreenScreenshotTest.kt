package com.agraabhi.oshodiscourses.feature.home

import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.agraabhi.oshodiscourses.core.model.Appearance
import com.agraabhi.oshodiscourses.core.testing.FakeAppServices
import com.agraabhi.oshodiscourses.core.testing.SampleCatalog
import com.agraabhi.oshodiscourses.core.ui.LocalAppServices
import com.agraabhi.oshodiscourses.core.ui.theme.OshoTheme
import com.github.takahirom.roborazzi.captureRoboImage
import com.google.common.truth.Truth.assertThat
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], qualifiers = "w393dp-h852dp-xxhdpi")
class HomeScreenScreenshotTest {
    @get:Rule
    val compose = createComposeRule()

    private var opened: String? = null

    private fun show(appearance: Appearance) {
        compose.setContent {
            CompositionLocalProvider(LocalAppServices provides FakeAppServices.preview()) {
                OshoTheme(appearance = appearance) {
                    HomeScreen(onOpenSeries = { opened = it })
                }
            }
        }
    }

    @Test
    fun placeholderLight() {
        show(Appearance.LIGHT)
        compose.onRoot().captureRoboImage("src/test/screenshots/home_placeholder_light.png")
    }

    @Test
    fun placeholderDark() {
        show(Appearance.DARK)
        compose.onRoot().captureRoboImage("src/test/screenshots/home_placeholder_dark.png")
    }

    @Test
    fun tappingASeriesOpensIt() {
        show(Appearance.LIGHT)
        compose.onNodeWithText(SampleCatalog.mahaGeeta.name).performClick()
        assertThat(opened).isEqualTo(SampleCatalog.mahaGeeta.id)
    }
}
