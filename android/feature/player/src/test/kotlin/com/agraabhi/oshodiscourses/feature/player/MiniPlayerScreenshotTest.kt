package com.agraabhi.oshodiscourses.feature.player

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.agraabhi.oshodiscourses.core.model.Appearance
import com.agraabhi.oshodiscourses.core.testing.FakeAppServices
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import com.github.takahirom.roborazzi.captureRoboImage
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], qualifiers = "w393dp-h110dp-xxhdpi")
class MiniPlayerScreenshotTest {
    @get:Rule
    val compose = createComposeRule()

    private fun show(services: FakeAppServices, appearance: Appearance, fontScale: Float? = null) {
        compose.setContent {
            TestHost(services, appearance, fontScale) {
                // Grouped background stands in for the page the bar floats over.
                Box(Modifier.fillMaxSize().background(Osho.colors.systemGroupedBackground).padding(vertical = 16.dp), contentAlignment = Alignment.Center) {
                    MiniPlayer(onOpenPlayer = {})
                }
            }
        }
    }

    private fun capture(name: String) = compose.onRoot().captureRoboImage("src/test/screenshots/mini_player_$name.png")

    @Test
    fun playingLight() {
        show(playerServices(configure = { copy(currentTime = 2_100.0) }), Appearance.LIGHT)
        capture("playing_light")
    }

    @Test
    fun pausedDark() {
        show(playerServices(isPlaying = false, configure = { copy(currentTime = 2_100.0) }), Appearance.DARK)
        capture("paused_dark")
    }

    @Test
    fun longTitleLight() {
        show(playerServices(series = LongSeries, index = 11), Appearance.LIGHT)
        capture("long_title_light")
    }

    /** A title without a trailing "#N" falls back to one line with the series name. */
    @Test
    fun unnumberedDark() {
        show(playerServices(configure = { copy(currentTitle = "Evening Darshan") }), Appearance.DARK)
        capture("unnumbered_dark")
    }

    @Test
    @Config(qualifiers = "w360dp-h140dp-xxhdpi")
    fun smallPhoneFontScale() {
        show(playerServices(series = LongSeries, index = 11), Appearance.LIGHT, fontScale = 1.5f)
        capture("small_phone_font_150_light")
    }
}
