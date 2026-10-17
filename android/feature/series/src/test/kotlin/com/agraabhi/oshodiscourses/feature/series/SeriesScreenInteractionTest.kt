package com.agraabhi.oshodiscourses.feature.series

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasScrollAction
import androidx.compose.ui.test.hasStateDescription
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToIndex
import androidx.compose.ui.test.performTouchInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadState
import com.agraabhi.oshodiscourses.core.testing.FakeAppServices
import com.google.common.truth.Truth.assertThat
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import android.os.Looper
import java.time.Duration

@RunWith(AndroidJUnit4::class)
@Config(sdk = [36], qualifiers = "w393dp-h852dp-xxhdpi")
class SeriesScreenInteractionTest {
    @get:Rule
    val compose = createComposeRule()

    private val series = SeriesFixtures.bird
    private var transcriptOpened: String? = null
    private var bookmarked = 0

    private fun show(services: FakeAppServices) {
        compose.setContent {
            TestHost(services) {
                SeriesScreen(
                    seriesID = series.id,
                    onOpenPlayer = {},
                    onBack = {},
                    onOpenTranscript = { transcriptOpened = it },
                    onAddBookmark = { bookmarked++ },
                )
            }
        }
    }

    private fun id(n: Int) = SeriesFixtures.id(series, n)

    private fun scrollToRows() = compose.onNode(hasScrollAction()).performScrollToIndex(2)

    @Test
    fun tappingANotDownloadedRowStartsTheDownloadAndShowsTheHint() {
        val services = SeriesFixtures.fresh(series)
        services.downloads.completeInstantly = false
        show(services)
        compose.onNodeWithContentDescription("Discourse 1").performClick()
        compose.onNodeWithText("Downloading...").assertIsDisplayed()
        assertThat(services.downloads.state(id(1))).isEqualTo(DownloadState.Queued)
        // The hint timer runs in viewModelScope on the main looper, not the compose clock.
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(SeriesViewModel.DOWNLOAD_HINT_MILLIS + 500))
        compose.waitForIdle()
        compose.onNodeWithText("Downloading...").assertDoesNotExist()
    }

    @Test
    fun tappingADownloadedRowPlaysTheSeriesQueueFromThere() {
        val services = SeriesFixtures.allStates()
        show(services)
        scrollToRows()
        compose.onNodeWithContentDescription("Discourse 2, completed, transcript available").performClick()
        compose.waitForIdle()
        val player = services.player.state.value
        assertThat(player.currentTrackId).isEqualTo(id(2))
        assertThat(player.queue.map { it.id }).containsExactly(id(1), id(2)).inOrder()
    }

    @Test
    fun theRowPlayButtonPausesTheCurrentTrack() {
        val services = SeriesFixtures.allStates()
        show(services)
        scrollToRows()
        compose.onNodeWithContentDescription("Pause").performClick()
        compose.waitForIdle()
        assertThat(services.player.state.value.isPlaying).isFalse()
    }

    @Test
    fun cancellingADownloadFromItsRing() {
        val services = SeriesFixtures.allStates()
        show(services)
        scrollToRows()
        compose.onNode(hasContentDescription("Cancel download").and(hasStateDescription("42 percent")))
            .performClick()
        compose.waitForIdle()
        assertThat(services.downloads.state(id(3))).isEqualTo(DownloadState.NotDownloaded)
    }

    @Test
    fun downloadAllAsksFirstThenQueuesEveryMissingDiscourse() {
        val services = SeriesFixtures.fresh(series)
        show(services)
        compose.onNodeWithText("Download All").performClick()
        compose.onNodeWithText("Download 9 discourses?").assertIsDisplayed()
        compose.onNodeWithText("This will download 9 discourses using approximately ~270 MB of storage.").assertIsDisplayed()
        compose.onNodeWithText("Download 9 (~270 MB)").performClick()
        compose.waitForIdle()
        assertThat(services.downloads.downloadedIDs.value).containsExactlyElementsIn((1..9).map(::id))
    }

    @Test
    fun cancellingTheDownloadAllDialogQueuesNothing() {
        val services = SeriesFixtures.fresh(series)
        show(services)
        compose.onNodeWithText("Download All").performClick()
        compose.onNodeWithText("Cancel").performClick()
        compose.waitForIdle()
        compose.onNodeWithText("Download 9 discourses?").assertDoesNotExist()
        assertThat(services.downloads.downloadedIDs.value).isEmpty()
    }

    @Test
    fun longPressMenuOffersTheCurrentTrackActions() {
        val services = SeriesFixtures.allStates()
        show(services)
        scrollToRows()
        compose.onNodeWithContentDescription("Discourse 1, transcript available").performTouchInput { longClick(center) }
        compose.onNodeWithText("Pause").assertIsDisplayed()
        compose.onNodeWithText("Add Bookmark…").assertIsDisplayed()
        compose.onNodeWithText("Remove Download").assertIsDisplayed()
        compose.onNodeWithText("Read Transcript").performClick()
        assertThat(transcriptOpened).isEqualTo(id(1))
    }

    @Test
    fun longPressMarksAsCompleteAndRemovesDownloads() {
        val services = SeriesFixtures.allStates()
        show(services)
        scrollToRows()
        compose.onNodeWithContentDescription("Discourse 1, transcript available").performTouchInput { longClick(center) }
        compose.onNodeWithText("Mark as Complete").performClick()
        compose.waitForIdle()
        assertThat(services.playbackState.isCompleted(id(1))).isTrue()

        compose.onNodeWithContentDescription("Discourse 1, completed, transcript available").performTouchInput { longClick(center) }
        compose.onNodeWithText("Remove Download").performClick()
        compose.waitForIdle()
        assertThat(services.downloads.state(id(1))).isEqualTo(DownloadState.NotDownloaded)
    }

    @Test
    fun notDownloadedRowsOfferDownloadInTheMenu() {
        val services = SeriesFixtures.fresh(series)
        show(services)
        compose.onNodeWithContentDescription("Discourse 1").performTouchInput { longClick(center) }
        compose.onNodeWithText("Add Bookmark…").assertDoesNotExist()
        compose.onNodeWithText("Download").performClick()
        compose.waitForIdle()
        assertThat(services.downloads.state(id(1))).isEqualTo(DownloadState.Downloaded)
    }

    @Test
    fun toolbarMarksEveryDiscourseCompleteAndIncomplete() {
        val services = SeriesFixtures.fresh(series)
        show(services)
        compose.onNodeWithContentDescription("More options").performClick()
        compose.onNodeWithText("Mark All Complete").performClick()
        compose.waitForIdle()
        assertThat(services.playbackState.state.value.completedDiscourseIDs).containsExactlyElementsIn((1..9).map(::id))
        compose.onNodeWithText("9/9 completed").assertIsDisplayed()

        compose.onNodeWithContentDescription("More options").performClick()
        compose.onNodeWithText("Mark All Incomplete").performClick()
        compose.waitForIdle()
        assertThat(services.playbackState.state.value.completedDiscourseIDs).isEmpty()
    }

    @Test
    fun useMobileDataClearsTheWaitingNotice() {
        val services = SeriesFixtures.allStates()
        show(services)
        compose.onNodeWithText("Use Mobile Data").performClick()
        compose.waitForIdle()
        assertThat(services.downloads.allowCellular).isTrue()
        compose.onNodeWithText("Use Mobile Data").assertDoesNotExist()
    }
}
