package com.agraabhi.oshodiscourses.feature.downloads

import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeLeft
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.agraabhi.oshodiscourses.core.domain.downloads.WaitingReason
import com.agraabhi.oshodiscourses.core.testing.FakeAppServices
import com.agraabhi.oshodiscourses.core.testing.SampleCatalog
import com.google.common.truth.Truth.assertThat
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [36], qualifiers = "w393dp-h1500dp-xxhdpi")
class DownloadsInteractionTest {
    @get:Rule
    val compose = createComposeRule()

    private var openedSeries: String? = null
    private var openedStats = 0
    private var openedBookmarks = 0

    private fun show(services: FakeAppServices) {
        compose.show(services) {
            DownloadsScreen(
                onOpenSeries = { openedSeries = it },
                onOpenBookmarks = { openedBookmarks++ },
                onOpenListeningStats = { openedStats++ },
            )
        }
    }

    @Test
    fun tappingARowPlaysThatDiscourse() {
        val services = Fixtures.populated(playing = false)
        show(services)
        compose.onNode(birdRow(2)).performClick()
        compose.waitForIdle()
        assertThat(services.player.state.value.currentTrackId).isEqualTo(Fixtures.bird[1].id)
    }

    @Test
    fun pauseButtonPausesTheCurrentTrack() {
        val services = Fixtures.populated(playing = true)
        show(services)
        compose.onNodeWithContentDescription("Pause").performClick()
        compose.waitForIdle()
        assertThat(services.player.state.value.isPlaying).isFalse()
    }

    @Test
    fun useMobileDataReleasesWaitingDownloads() {
        val services = Fixtures.populated(waiting = WaitingReason.WIFI)
        show(services)
        compose.onNodeWithText("Use Mobile Data").performClick()
        compose.waitForIdle()
        assertThat(services.downloads.allowCellular).isTrue()
        compose.onNodeWithText("Use Mobile Data").assertDoesNotExist()
    }

    @Test
    fun cancelStopsTheInProgressDownload() {
        val services = Fixtures.populated()
        show(services)
        compose.onAllNodes(hasContentDescription("Cancel download"))[0].performClick()
        compose.waitForIdle()
        assertThat(services.downloads.state(Fixtures.geeta[1].id).isActive).isFalse()
        compose.onNodeWithText("Downloading").assertDoesNotExist()
    }

    @Test
    fun seriesMenuDeletesTheSeriesAfterConfirming() {
        val services = Fixtures.populated()
        show(services)
        compose.onAllNodes(hasContentDescription("Series options"))[0].performClick()
        compose.onNodeWithText("Delete All in Series").performClick()
        compose.onNodeWithText("Delete all downloads in A Bird on the Wing?").assertExists()
        compose.onNodeWithText("Delete Series Downloads").performClick()
        compose.waitForIdle()
        assertThat(services.downloads.downloadedIDs.value).containsExactly(Fixtures.geeta[0].id)
    }

    @Test
    fun cancellingTheConfirmationKeepsDownloads() {
        val services = Fixtures.populated()
        show(services)
        compose.onNodeWithContentDescription("More options").performClick()
        compose.onNodeWithText("Delete All").performClick()
        compose.onNodeWithText("Delete all 3 downloaded discourses?").assertExists()
        compose.onNodeWithText("Cancel").performClick()
        compose.waitForIdle()
        assertThat(services.downloads.downloadedIDs.value).hasSize(3)
    }

    @Test
    fun deleteAllRemovesEveryDownload() {
        val services = Fixtures.populated()
        show(services)
        compose.onNodeWithContentDescription("More options").performClick()
        compose.onNodeWithText("Delete All").performClick()
        compose.onNodeWithText("Delete All").performClick()
        compose.waitForIdle()
        assertThat(services.downloads.downloadedIDs.value).isEmpty()
        compose.onNodeWithText("No Downloads").assertExists()
    }

    @Test
    fun swipingLeftDeletesADownload() {
        val services = Fixtures.populated()
        show(services)
        compose.onNode(birdRow(2)).performTouchInput { swipeLeft() }
        compose.waitForIdle()
        assertThat(services.downloads.downloadedIDs.value).doesNotContain(Fixtures.bird[1].id)
    }

    @Test
    fun selectModeDeletesTheSelection() {
        val services = Fixtures.populated()
        show(services)
        compose.onNodeWithContentDescription("More options").performClick()
        compose.onNodeWithText("Select").performClick()
        compose.onNodeWithText("Select discourses").assertExists()
        compose.onNodeWithText("Discourse 2").performClick()
        compose.onNodeWithText("1 selected").assertExists()
        compose.onNodeWithText("Delete").performClick()
        compose.waitForIdle()
        assertThat(services.downloads.downloadedIDs.value).containsExactly(Fixtures.bird[0].id, Fixtures.geeta[0].id)
        compose.onNodeWithText("Select discourses").assertDoesNotExist()
    }

    @Test
    fun searchFiltersBySeriesName() {
        show(Fixtures.populated())
        compose.onNodeWithContentDescription("Search downloads").performTextInput("maha")
        compose.onNode(hasText("Ashtavakra Maha Geeta") and hasClickAction()).assertExists()
        compose.onNodeWithText("A Bird on the Wing").assertDoesNotExist()
        compose.onNodeWithText("Previously Downloaded").assertDoesNotExist()
    }

    @Test
    fun getRedownloadsAPreviousDownload() {
        val services = Fixtures.populated()
        show(services)
        compose.onNodeWithText("GET ~30 MB").performClick()
        compose.waitForIdle()
        assertThat(services.downloads.downloadedIDs.value).contains(Fixtures.bird[2].id)
    }

    @Test
    fun headerAndActivityRowsNavigate() {
        show(Fixtures.populated())
        compose.onNode(hasText("Ashtavakra Maha Geeta") and hasClickAction()).performClick()
        assertThat(openedSeries).isEqualTo(SampleCatalog.mahaGeeta.id)
        compose.onNodeWithText("Listening Stats").performClick()
        compose.onNodeWithText("Bookmarks").performClick()
        assertThat(openedStats).isEqualTo(1)
        assertThat(openedBookmarks).isEqualTo(1)
        compose.onNodeWithText("5 saved").assertExists()
        compose.onNodeWithText("18h 55m listened").assertExists()
    }
}

/** The downloaded row, not the in-progress caption with the same text. */
private fun birdRow(number: Int) = hasText("Discourse $number") and hasClickAction()
