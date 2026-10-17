package com.agraabhi.oshodiscourses.feature.downloads

import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.performTextInput
import com.agraabhi.oshodiscourses.core.ui.components.SEARCH_REVEAL_TAG
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.agraabhi.oshodiscourses.core.domain.downloads.WaitingReason
import com.agraabhi.oshodiscourses.core.model.Appearance
import com.github.takahirom.roborazzi.captureRoboImage
import com.github.takahirom.roborazzi.captureScreenRoboImage
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

private const val DIR = "src/test/screenshots"

@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], qualifiers = "w393dp-h852dp-xxhdpi")
class DownloadsScreenshotTest {
    @get:Rule
    val compose = createComposeRule()

    private fun downloads(services: com.agraabhi.oshodiscourses.core.testing.FakeAppServices, appearance: Appearance = Appearance.LIGHT, fontScale: Float = 1f) {
        compose.show(services, appearance, fontScale) {
            DownloadsScreen(onOpenSeries = {}, onOpenBookmarks = {}, onOpenListeningStats = {}, onAddBookmark = {})
        }
    }

    /** Popups and dialogs live in their own windows, so let them finish animating in first. */
    private fun settle() {
        compose.waitForIdle()
        compose.mainClock.advanceTimeBy(1_000)
        compose.waitForIdle()
    }

    @Test
    fun populatedLight() {
        downloads(Fixtures.populated())
        compose.onRoot().captureRoboImage("$DIR/downloads_populated_light.png")
    }

    @Test
    fun populatedDark() {
        downloads(Fixtures.populated(), Appearance.DARK)
        compose.onRoot().captureRoboImage("$DIR/downloads_populated_dark.png")
    }

    @Test
    fun populatedFullPageLight() {
        RuntimeEnvironment.setQualifiers("w393dp-h1500dp-xxhdpi")
        downloads(Fixtures.populated())
        compose.onRoot().captureRoboImage("$DIR/downloads_populated_full_light.png")
    }

    @Test
    fun populatedFullPageDark() {
        RuntimeEnvironment.setQualifiers("w393dp-h1500dp-xxhdpi")
        downloads(Fixtures.populated(), Appearance.DARK)
        compose.onRoot().captureRoboImage("$DIR/downloads_populated_full_dark.png")
    }

    @Test
    fun emptyLight() {
        downloads(Fixtures.empty())
        compose.onRoot().captureRoboImage("$DIR/downloads_empty_light.png")
    }

    @Test
    fun emptyDark() {
        downloads(Fixtures.empty(), Appearance.DARK)
        compose.onRoot().captureRoboImage("$DIR/downloads_empty_dark.png")
    }

    @Test
    fun waitingForWifi() {
        downloads(Fixtures.populated(waiting = WaitingReason.WIFI))
        compose.onRoot().captureRoboImage("$DIR/downloads_waiting_wifi_light.png")
    }

    @Test
    fun waitingForWifiDark() {
        downloads(Fixtures.populated(waiting = WaitingReason.WIFI), Appearance.DARK)
        compose.onRoot().captureRoboImage("$DIR/downloads_waiting_wifi_dark.png")
    }

    @Test
    fun waitingForConnection() {
        downloads(Fixtures.populated(waiting = WaitingReason.CONNECTION))
        compose.onRoot().captureRoboImage("$DIR/downloads_waiting_connection_light.png")
    }

    @Test
    fun searchNoResults() {
        downloads(Fixtures.populated())
        // The field hides until a pull reveals it, so this taps it through semantics.
        compose.onNodeWithTag(SEARCH_REVEAL_TAG).performSemanticsAction(SemanticsActions.OnClick)
        compose.onNodeWithContentDescription("Search downloads").performTextInput("zen")
        compose.onRoot().captureRoboImage("$DIR/downloads_search_no_results.png")
    }

    @Test
    fun editingWithSelection() {
        downloads(Fixtures.populated())
        compose.onNodeWithContentDescription("More options").performClick()
        compose.onNodeWithText("Select").performClick()
        compose.onNodeWithText("Discourse 2").performClick()
        compose.onRoot().captureRoboImage("$DIR/downloads_editing_light.png")
    }

    @Test
    fun toolbarMenu() {
        downloads(Fixtures.populated())
        compose.onNodeWithContentDescription("More options").performClick()
        settle()
        captureScreenRoboImage("$DIR/downloads_toolbar_menu.png")
    }

    @Test
    fun deleteAllDialog() {
        downloads(Fixtures.populated())
        compose.onNodeWithContentDescription("More options").performClick()
        compose.onNodeWithText("Delete All").performClick()
        settle()
        captureScreenRoboImage("$DIR/downloads_delete_all_dialog.png")
    }

    @Test
    fun deleteSeriesDialogDark() {
        downloads(Fixtures.populated(), Appearance.DARK)
        compose.onAllNodes(hasContentDescription("Series options"))[0].performClick()
        compose.onNodeWithText("Delete All in Series").performClick()
        settle()
        captureScreenRoboImage("$DIR/downloads_delete_series_dialog_dark.png")
    }

    @Test
    fun fontScale150() {
        downloads(Fixtures.populated(waiting = WaitingReason.WIFI), fontScale = 1.5f)
        compose.onRoot().captureRoboImage("$DIR/downloads_font150.png")
    }

    @Test
    fun fontScale200() {
        downloads(Fixtures.populated(), fontScale = 2f)
        compose.onRoot().captureRoboImage("$DIR/downloads_font200.png")
    }

    @Test
    fun smallPhone() {
        RuntimeEnvironment.setQualifiers("w360dp-h740dp-xhdpi")
        downloads(Fixtures.populated(waiting = WaitingReason.WIFI))
        compose.onRoot().captureRoboImage("$DIR/downloads_small_phone.png")
    }
}
