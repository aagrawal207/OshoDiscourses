package com.agraabhi.oshodiscourses.feature.downloads

import androidx.compose.runtime.getValue
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeLeft
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.agraabhi.oshodiscourses.core.model.Appearance
import com.agraabhi.oshodiscourses.core.testing.FakeAppServices
import com.github.takahirom.roborazzi.captureRoboImage
import com.google.common.truth.Truth.assertThat
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
class BookmarksAndStatsScreenshotTest {
    @get:Rule
    val compose = createComposeRule()

    private var backs = 0

    private fun bookmarks(services: FakeAppServices, appearance: Appearance = Appearance.LIGHT, fontScale: Float = 1f) {
        compose.show(services, appearance, fontScale) { BookmarksScreen(onBack = { backs++ }) }
    }

    /** Stats and History with a pinned "today" so the day labels never drift. */
    private fun stats(services: FakeAppServices, history: Boolean, appearance: Appearance = Appearance.LIGHT, fontScale: Float = 1f) {
        compose.show(services, appearance, fontScale) {
            val vm = viewModel {
                ListeningStatsViewModel(services.listeningStats, services.playbackState, services.catalog) { Fixtures.today }
            }
            val state by vm.state.collectAsStateWithLifecycle()
            if (history) ListeningHistoryContent(state, onBack = {}) else ListeningStatsContent(state, onOpenHistory = {}, onBack = {})
        }
    }

    @Test fun bookmarksLight() = bookmarks(Fixtures.populated()).also { capture("bookmarks_light") }

    @Test fun bookmarksDark() = bookmarks(Fixtures.populated(), Appearance.DARK).also { capture("bookmarks_dark") }

    @Test fun bookmarksEmptyLight() = bookmarks(Fixtures.empty()).also { capture("bookmarks_empty_light") }

    @Test fun bookmarksEmptyDark() = bookmarks(Fixtures.empty(), Appearance.DARK).also { capture("bookmarks_empty_dark") }

    @Test
    fun bookmarksFilteredEmpty() {
        bookmarks(Fixtures.populated())
        compose.onNodeWithTag("bookmarks.chips").performScrollToNode(hasText("Meditation"))
        compose.onNodeWithText("Meditation").performClick()
        capture("bookmarks_filtered_empty")
    }

    @Test fun bookmarksFont150() = bookmarks(Fixtures.populated(), fontScale = 1.5f).also { capture("bookmarks_font150") }

    @Test fun bookmarksFont200() = bookmarks(Fixtures.populated(), fontScale = 2f).also { capture("bookmarks_font200") }

    @Test
    fun bookmarksSmallPhone() {
        RuntimeEnvironment.setQualifiers("w360dp-h740dp-xhdpi")
        bookmarks(Fixtures.populated())
        capture("bookmarks_small_phone")
    }

    @Test fun statsLight() = stats(Fixtures.populated(), history = false).also { capture("stats_light") }

    @Test fun statsDark() = stats(Fixtures.populated(), history = false, Appearance.DARK).also { capture("stats_dark") }

    @Test fun statsEmpty() = stats(Fixtures.empty(), history = false).also { capture("stats_empty_light") }

    @Test fun statsFont150() = stats(Fixtures.populated(), history = false, fontScale = 1.5f).also { capture("stats_font150") }

    @Test fun statsFont200() = stats(Fixtures.populated(), history = false, fontScale = 2f).also { capture("stats_font200") }

    @Test
    fun statsSmallPhone() {
        RuntimeEnvironment.setQualifiers("w360dp-h740dp-xhdpi")
        stats(Fixtures.populated(), history = false)
        capture("stats_small_phone")
    }

    @Test fun historyLight() = stats(Fixtures.populated(), history = true).also { capture("history_light") }

    @Test fun historyDark() = stats(Fixtures.populated(), history = true, Appearance.DARK).also { capture("history_dark") }

    @Test fun historyEmpty() = stats(Fixtures.empty(), history = true).also { capture("history_empty_light") }

    @Test fun historyFont200() = stats(Fixtures.populated(), history = true, fontScale = 2f).also { capture("history_font200") }

    @Test
    fun bookmarkFilterSwipeAndBack() {
        val services = Fixtures.populated()
        bookmarks(services)
        compose.onNode(hasText("Funny") and hasClickAction()).performClick()
        compose.onNodeWithText("Demonetization predicted").assertExists()
        compose.onNodeWithText("Don't be a soldier").assertDoesNotExist()
        compose.onNode(hasText("Funny") and hasClickAction()).performClick()
        compose.onNodeWithText("Don't be a soldier").assertExists()

        compose.onNode(hasText("Don't be a soldier")).performTouchInput { swipeLeft() }
        compose.waitForIdle()
        assertThat(services.bookmarks.bookmarks.value.map { it.id }).doesNotContain("b1")

        compose.onAllNodesWithContentDescription("Back")[0].performClick()
        assertThat(backs).isEqualTo(1)
    }

    @Test
    fun bookmarkTrailingButtonsPlayAndDownload() {
        val services = Fixtures.populated(playing = false)
        bookmarks(services)
        compose.onAllNodesWithContentDescription("Play")[0].performClick()
        compose.waitForIdle()
        assertThat(services.player.state.value.currentTrackId).isEqualTo(Fixtures.bird[0].id)
        assertThat(services.player.state.value.currentTime).isEqualTo(2_051.0)
        compose.onAllNodesWithContentDescription("Download")[0].performClick()
        compose.waitForIdle()
        assertThat(services.downloads.downloadedIDs.value).contains(Fixtures.bird[2].id)
    }

    @Test
    fun statsOpensHistoryInPlaceAndBack() {
        compose.show(Fixtures.populated()) { ListeningStatsScreen(onBack = {}) }
        compose.onNodeWithText("Full Listening History").performClick()
        compose.onNodeWithText("Daily Log").assertExists()
        compose.onAllNodesWithContentDescription("Back")[0].performClick()
        compose.onNodeWithText("Time Periods").assertExists()
    }

    private fun capture(name: String) {
        compose.onRoot().captureRoboImage("$DIR/$name.png")
    }
}
