package com.agraabhi.oshodiscourses.feature.player

import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeDown
import androidx.compose.ui.test.swipeRight
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.agraabhi.oshodiscourses.core.domain.bookmarks.BookmarkCategory
import com.agraabhi.oshodiscourses.core.domain.sleep.SleepTimerMode
import com.agraabhi.oshodiscourses.core.testing.FakeAppServices
import com.agraabhi.oshodiscourses.core.testing.SampleCatalog
import com.google.common.truth.Truth.assertThat
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [36], qualifiers = "w393dp-h852dp-xxhdpi")
class PlayerScreenInteractionTest {
    @get:Rule
    val compose = createComposeRule()

    private var dismissed = 0
    private var openedSeries: String? = null
    private var openedTranscript: String? = null
    private var outputSwitcherShown = 0

    private fun show(services: FakeAppServices): FakeAppServices {
        compose.setContent {
            TestHost(services) {
                PlayerScreen(
                    onDismiss = { dismissed++ },
                    onOpenTranscript = { openedTranscript = it },
                    onOpenSeries = { openedSeries = it },
                    onShowOutputSwitcher = { outputSwitcherShown++ },
                )
            }
        }
        return services
    }

    private val player get() = services.player.state.value
    private lateinit var services: FakeAppServices

    private fun start(services: FakeAppServices = playerServices()) {
        this.services = show(services)
    }

    @Test
    fun pauseTogglesAndAsksForAReviewMoment() {
        start()
        compose.onNodeWithContentDescription("Pause").performClick()
        assertThat(player.isPlaying).isFalse()
        assertThat(services.reviewPrompter.requests).isEqualTo(1)
        compose.onNodeWithContentDescription("Play").performClick()
        assertThat(player.isPlaying).isTrue()
        assertThat(services.reviewPrompter.requests).isEqualTo(1)
    }

    @Test
    fun skipButtonsMoveByFifteenAndThirty() {
        start()
        compose.onNodeWithContentDescription("Skip back 15 seconds").performClick()
        assertThat(player.currentTime).isEqualTo(488.0)
        compose.onNodeWithContentDescription("Skip forward 30 seconds").performClick()
        assertThat(player.currentTime).isEqualTo(518.0)
    }

    @Test
    fun nextAndPreviousFollowTheQueue() {
        start(playerServices(index = 2, configure = { copy(currentTime = 2.0) }))
        compose.onNodeWithContentDescription("Next").assertIsNotEnabled()
        compose.onNodeWithContentDescription("Previous").assertIsEnabled().performClick()
        assertThat(player.currentIndex).isEqualTo(1)
        compose.onNodeWithContentDescription("Next").assertIsEnabled().performClick()
        assertThat(player.currentIndex).isEqualTo(2)
    }

    @Test
    fun previousIsDisabledAtTheStartOfTheFirstDiscourse() {
        start(playerServices(configure = { copy(currentTime = 1.0) }))
        compose.onNodeWithContentDescription("Previous").assertIsNotEnabled()
    }

    @Test
    fun seriesTitleOpensTheSeries() {
        start()
        compose.onNodeWithContentDescription(SampleCatalog.birdOnTheWing.name).performClick()
        assertThat(openedSeries).isEqualTo(SampleCatalog.birdOnTheWing.id)
    }

    @Test
    fun transcriptOpensForTheCurrentDiscourse() {
        start()
        compose.onNodeWithContentDescription("Transcript").performClick()
        assertThat(openedTranscript).isEqualTo(SampleCatalog.firstDiscourse.id)
    }

    @Test
    fun transcriptIsDisabledWithoutOne() {
        start(playerServices(series = SampleCatalog.mahaGeeta))
        compose.onNodeWithContentDescription("Transcript").assertIsNotEnabled()
    }

    @Test
    fun upNextIsDisabledForASingleItemQueue() {
        start(playerServices(configure = { copy(queue = queue.take(1)) }))
        compose.onNodeWithContentDescription("Up Next").assertIsNotEnabled()
    }

    @Test
    fun outputButtonOpensTheSwitcher() {
        start()
        compose.onNodeWithContentDescription("AirPlay and output device").performClick()
        assertThat(outputSwitcherShown).isEqualTo(1)
    }

    @Test
    fun remainingTimeTogglesToTotal() {
        start()
        compose.onNodeWithContentDescription("Time remaining")
            .assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "1:29:58"))
            .performClick()
        compose.onNodeWithContentDescription("Total time")
            .assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "1:38:21"))
            .performClick()
        compose.onNodeWithContentDescription("Time remaining").assertIsDisplayed()
    }

    @Test
    fun scrubbingSeeksWithHistoryAndBackReturns() {
        start()
        compose.onNodeWithContentDescription("Playback position").performTouchInput { swipeRight(startX = left + 60f, endX = centerX) }
        assertThat(player.currentTime).isGreaterThan(2_000.0)
        assertThat(player.previousPosition).isEqualTo(503.0)
        compose.onNodeWithText("Back to 8:23").performClick()
        assertThat(player.currentTime).isEqualTo(503.0)
    }

    @Test
    fun speedPresetsAndStepsUseTheGrid() {
        start()
        compose.onNodeWithContentDescription("Playback speed").performClick()
        compose.onNodeWithContentDescription("1.5 times").performClick()
        assertThat(player.playbackRate).isEqualTo(1.5f)
        compose.onNodeWithContentDescription("Faster").performClick()
        assertThat(player.playbackRate).isEqualTo(1.55f)
        compose.onNodeWithContentDescription("Slower").performClick()
        compose.onNodeWithContentDescription("Slower").performClick()
        assertThat(player.playbackRate).isEqualTo(1.45f)
    }

    @Test
    fun fasterIsDisabledAtTheTop() {
        start(playerServices(configure = { copy(playbackRate = 2f) }))
        compose.onNodeWithContentDescription("Playback speed").performClick()
        compose.onNodeWithContentDescription("Faster").assertIsNotEnabled()
    }

    @Test
    fun sleepTimerStartsAndCancels() {
        start()
        compose.onNodeWithContentDescription("Sleep timer").performClick()
        compose.onNodeWithText("15 min").performClick()
        assertThat(services.sleepTimer.state.value.mode).isEqualTo(SleepTimerMode.COUNTDOWN)
        assertThat(services.sleepTimer.state.value.remainingTime).isEqualTo(900.0)
        compose.onNodeWithContentDescription("Sleep timer").assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "15:00"))

        compose.onNodeWithContentDescription("Sleep timer").performClick()
        compose.onNodeWithText("Cancel").performClick()
        assertThat(services.sleepTimer.state.value.isActive).isFalse()
    }

    @Test
    fun sleepAtEndOfDiscourse() {
        start()
        compose.onNodeWithContentDescription("Sleep timer").performClick()
        compose.onNodeWithText("End of discourse").performClick()
        assertThat(services.sleepTimer.state.value.mode).isEqualTo(SleepTimerMode.END_OF_DISCOURSE)
        compose.onNodeWithContentDescription("Sleep timer").assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "End"))
    }

    @Test
    fun bookmarkCapturesTheTapTimeAndSaves() {
        start()
        compose.onNodeWithContentDescription("Add bookmark").performClick()
        // Playback moving on must not change the captured moment.
        services.player.state.value = player.copy(currentTime = 900.0)
        compose.onNodeWithText("Funny").performClick()
        compose.onNodeWithContentDescription("What caught your attention?").performTextInput("The dog koan")
        compose.onNodeWithText("Save").performClick()

        val saved = services.bookmarks.bookmarks.value.single()
        assertThat(saved.timestamp).isEqualTo(503.0)
        assertThat(saved.category).isEqualTo(BookmarkCategory.FUNNY)
        assertThat(saved.note).isEqualTo("The dog koan")
        assertThat(saved.customCategory).isNull()
        assertThat(saved.discourseID).isEqualTo(SampleCatalog.firstDiscourse.id)
        compose.onNodeWithText("Bookmarked at 8:23").assertIsDisplayed()
    }

    @Test
    fun customBookmarkCategoryKeepsItsName() {
        start()
        compose.onNodeWithContentDescription("Add bookmark").performClick()
        compose.onNodeWithText("Custom").performClick()
        compose.onNodeWithContentDescription("Custom category name").performTextInput("Zen")
        compose.onNodeWithText("Save").performClick()
        val saved = services.bookmarks.bookmarks.value.single()
        assertThat(saved.category).isEqualTo(BookmarkCategory.CUSTOM)
        assertThat(saved.customCategory).isEqualTo("Zen")
    }

    @Test
    fun cancelledBookmarkSavesNothing() {
        start()
        compose.onNodeWithContentDescription("Add bookmark").performClick()
        compose.onNodeWithText("Cancel").performClick()
        assertThat(services.bookmarks.bookmarks.value).isEmpty()
        compose.onNodeWithText("Add Bookmark").assertDoesNotExist()
    }

    @Test
    fun queueRowPlaysThatDiscourse() {
        start()
        compose.onNodeWithContentDescription("Up Next").performClick()
        compose.onNodeWithContentDescription("A Bird on the Wing - #3, A Bird on the Wing").performClick()
        assertThat(player.currentIndex).isEqualTo(2)
        compose.onNodeWithText("Up Next").assertDoesNotExist()
    }

    @Test
    fun denoiseOpensAsASheetAndDoneCloses() {
        start()
        compose.onNodeWithContentDescription("DeNoise").performClick()
        compose.onNodeWithText("Enable DeNoise").performClick()
        assertThat(services.denoise.state.value.isEnabled).isTrue()
        compose.onNodeWithText("Done").performClick()
        compose.onNodeWithText("Enable DeNoise").assertDoesNotExist()
    }

    @Test
    fun swipingDownDismisses() {
        start()
        compose.onRoot().performTouchInput { swipeDown(startY = top + 200f, endY = bottom - 100f) }
        assertThat(dismissed).isEqualTo(1)
    }

    @Test
    fun aShortSwipeSpringsBack() {
        start()
        compose.onRoot().performTouchInput { swipeDown(startY = top + 200f, endY = top + 260f, durationMillis = 800) }
        assertThat(dismissed).isEqualTo(0)
    }

    @Test
    fun playPauseExposesItsAction() {
        start()
        compose.onNodeWithContentDescription("Pause").assert(SemanticsMatcher.keyIsDefined(SemanticsActions.OnClick))
    }
}
