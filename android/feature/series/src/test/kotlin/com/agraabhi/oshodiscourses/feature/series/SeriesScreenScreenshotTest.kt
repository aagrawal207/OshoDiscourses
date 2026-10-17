package com.agraabhi.oshodiscourses.feature.series

import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performScrollToIndex
import androidx.compose.ui.test.hasScrollAction
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.agraabhi.oshodiscourses.core.model.Appearance
import com.agraabhi.oshodiscourses.core.testing.FakeAppServices
import com.github.takahirom.roborazzi.ExperimentalRoborazziApi
import com.github.takahirom.roborazzi.captureRoboImage
import com.github.takahirom.roborazzi.captureScreenRoboImage
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], qualifiers = "w393dp-h852dp-xxhdpi")
@OptIn(ExperimentalRoborazziApi::class)
class SeriesScreenScreenshotTest {
    @get:Rule
    val compose = createComposeRule()

    private fun show(services: FakeAppServices, seriesID: String, appearance: Appearance = Appearance.LIGHT, fontScale: Float = 1f) {
        compose.setContent {
            TestHost(services, appearance, fontScale) {
                SeriesScreen(seriesID = seriesID, onOpenPlayer = {}, onBack = {}, onOpenTranscript = {}, onAddBookmark = {})
            }
        }
    }

    private fun capture(name: String) = compose.onRoot().captureRoboImage("src/test/screenshots/$name.png")

    private fun scrollToRows() {
        compose.onNode(hasScrollAction()).performScrollToIndex(2)
    }

    @Test
    fun headerLight() {
        show(SeriesFixtures.allStates(), SeriesFixtures.bird.id)
        capture("series_header_light")
    }

    @Test
    fun headerDark() {
        show(SeriesFixtures.allStates(), SeriesFixtures.bird.id, Appearance.DARK)
        capture("series_header_dark")
    }

    @Test
    fun rowStatesLight() {
        show(SeriesFixtures.allStates(), SeriesFixtures.bird.id)
        scrollToRows()
        capture("series_rows_light")
    }

    @Test
    fun rowStatesDark() {
        show(SeriesFixtures.allStates(), SeriesFixtures.bird.id, Appearance.DARK)
        scrollToRows()
        capture("series_rows_dark")
    }

    @Test
    fun freshHindiDark() {
        show(SeriesFixtures.fresh(SeriesFixtures.hindi), SeriesFixtures.hindi.id, Appearance.DARK)
        capture("series_fresh_hindi_dark")
    }

    @Test
    fun longTitleLight() {
        val series = SeriesFixtures.longTitle
        show(SeriesFixtures.fresh(series, setOf(SeriesFixtures.id(series, 1))), series.id)
        capture("series_long_title_light")
    }

    @Test
    fun fontScale150() {
        show(SeriesFixtures.allStates(), SeriesFixtures.bird.id, fontScale = 1.5f)
        capture("series_font150_light")
        scrollToRows()
        capture("series_font150_rows_light")
    }

    @Test
    fun fontScale200() {
        show(SeriesFixtures.allStates(), SeriesFixtures.bird.id, Appearance.DARK, fontScale = 2f)
        capture("series_font200_dark")
        scrollToRows()
        capture("series_font200_rows_dark")
    }

    @Test
    @Config(qualifiers = "w360dp-h740dp-xxhdpi")
    fun smallPhone() {
        val series = SeriesFixtures.longTitle
        show(SeriesFixtures.fresh(series, setOf(SeriesFixtures.id(series, 1))), series.id)
        capture("series_small_phone_light")
    }

    @Test
    @Config(qualifiers = "w360dp-h740dp-xxhdpi")
    fun smallPhoneRows() {
        show(SeriesFixtures.allStates(), SeriesFixtures.bird.id)
        scrollToRows()
        capture("series_small_phone_rows_light")
    }

    @Test
    fun downloadAllDialog() {
        show(SeriesFixtures.fresh(SeriesFixtures.bird), SeriesFixtures.bird.id)
        compose.onNodeWithText("Download All").performClick()
        compose.waitForIdle()
        captureScreenRoboImage("src/test/screenshots/series_download_all_dialog_light.png")
    }

    @Test
    fun downloadAllDialogDark() {
        show(SeriesFixtures.fresh(SeriesFixtures.longTitle), SeriesFixtures.longTitle.id, Appearance.DARK)
        compose.onNodeWithText("Download All").performClick()
        compose.waitForIdle()
        captureScreenRoboImage("src/test/screenshots/series_download_all_dialog_dark.png")
    }

    @Test
    fun rowContextMenu() {
        show(SeriesFixtures.allStates(), SeriesFixtures.bird.id)
        scrollToRows()
        compose.onNodeWithContentDescription("Discourse 1, transcript available").performTouchInput { longClick(center) }
        compose.waitForIdle()
        captureScreenRoboImage("src/test/screenshots/series_context_menu_light.png")
    }

    @Test
    fun toolbarMenuDark() {
        show(SeriesFixtures.allStates(), SeriesFixtures.bird.id, Appearance.DARK)
        compose.onNodeWithContentDescription("More options").performClick()
        compose.waitForIdle()
        captureScreenRoboImage("src/test/screenshots/series_toolbar_menu_dark.png")
    }
}
