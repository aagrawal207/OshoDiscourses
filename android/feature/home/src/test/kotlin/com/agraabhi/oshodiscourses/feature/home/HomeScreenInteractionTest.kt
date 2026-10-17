package com.agraabhi.oshodiscourses.feature.home

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToIndex
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.agraabhi.oshodiscourses.core.testing.FakeAppServices
import com.google.common.truth.Truth.assertThat
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [36], qualifiers = "w393dp-h852dp-xxhdpi")
class HomeScreenInteractionTest {
    @get:Rule
    val compose = createComposeRule()

    private var opened: String? = null
    private var supportOpened = 0
    private var supportDismissed: (() -> Unit)? = null

    private fun show(services: FakeAppServices, support: Boolean = false) {
        compose.setContent {
            TestHost(services) {
                HomeScreen(
                    onOpenSeries = { opened = it },
                    onOpenSupport = if (support) { done -> supportOpened++; supportDismissed = done } else null,
                )
            }
        }
    }

    @Test
    fun theContinueHeaderOpensItsSeries() {
        show(HomeFixtures.populated())
        compose.onAllNodesWithText(HomeFixtures.vbt.name).onFirst().performClick()
        assertThat(opened).isEqualTo(HomeFixtures.vbt.id)
    }

    @Test
    fun theCurrentRowTogglesPlaybackAndOthersStartTheirQueue() {
        val services = HomeFixtures.populated()
        show(services)
        compose.onNodeWithContentDescription("Pause").performClick()
        compose.waitForIdle()
        assertThat(services.player.state.value.isPlaying).isFalse()

        compose.onAllNodesWithText("Discourse 5")[1].performClick()
        compose.waitForIdle()
        val player = services.player.state.value
        assertThat(player.currentTrackId).isEqualTo(HomeFixtures.id(HomeFixtures.mahaGeeta, 5))
        assertThat(player.isPlaying).isTrue()
    }

    @Test
    fun dismissingARowRemovesItFromContinueListening() {
        val services = HomeFixtures.populated()
        show(services)
        compose.onAllNodesWithContentDescription("Remove from Continue Listening").onFirst().performClick()
        compose.waitForIdle()
        assertThat(services.playbackState.state.value.recentlyPlayed).doesNotContain(HomeFixtures.continueIDs.first())
    }

    @Test
    fun clearAllDismissesEveryCountedItem() {
        val services = HomeFixtures.populated()
        show(services)
        compose.onAllNodesWithText("Clear All").onFirst().performClick()
        compose.waitForIdle()
        assertThat(services.playbackState.state.value.recentlyPlayed).isEmpty()
        compose.onNodeWithText("Continue Listening").assertDoesNotExist()
        compose.onNodeWithText("Recently Completed").assertIsDisplayed()
    }

    @Test
    fun recentlyCompletedRowsOpenTheSeriesAndCanBeCleared() {
        val services = HomeFixtures.populated()
        show(services)
        compose.onNodeWithText("Discourse 4").performClick()
        assertThat(opened).isEqualTo(HomeFixtures.mahaGeeta.id)

        compose.onAllNodesWithContentDescription("Remove from Recently Completed").onFirst().performClick()
        compose.waitForIdle()
        assertThat(services.playbackState.state.value.listenedCompleted).containsExactly(HomeFixtures.id(HomeFixtures.bird, 1))

        compose.onAllNodesWithText("Clear All")[1].performClick()
        compose.waitForIdle()
        compose.onNodeWithText("Recently Completed").assertDoesNotExist()
    }

    @Test
    fun aShelfCardOpensItsSeries() {
        show(HomeFixtures.newUser())
        compose.onNodeWithText("Popular in Hindi").assertIsDisplayed()
        compose.onAllNodesWithText(HomeFixtures.jeevan.name).onFirst().performClick()
        assertThat(opened).isEqualTo(HomeFixtures.jeevan.id)
    }

    @Test
    fun shelvesFollowTheLanguageSetting() {
        show(HomeFixtures.populated(language = com.agraabhi.oshodiscourses.core.model.LanguageFilter.HINDI))
        compose.onNodeWithTag(LARGE_TITLE_LIST_TAG).performScrollToIndex(3)
        compose.onNodeWithText("Popular in Hindi").assertIsDisplayed()
        compose.onNodeWithText("Popular in English").assertDoesNotExist()
    }

    @Test
    fun supportCardOpensTheSheetOnceAndHidesWhileItIsOpen() {
        val services = HomeFixtures.populated(allowSupport = true, recent = emptyList(), completed = emptyList())
        show(services, support = true)
        compose.onNodeWithText("Optional support helps me keep improving Osho Talks.").assertIsDisplayed()
        compose.onNodeWithText("Support").performClick()
        compose.waitForIdle()
        assertThat(supportOpened).isEqualTo(1)
        compose.onNodeWithText("Optional support helps me keep improving Osho Talks.").assertDoesNotExist()
        assertThat(services.engagement.isSupportPresentationActive.value).isTrue()

        supportDismissed!!.invoke()
        compose.waitForIdle()
        compose.onNodeWithText("Optional support helps me keep improving Osho Talks.").assertIsDisplayed()
    }

    @Test
    fun notNowSnoozesTheSupportCard() {
        val services = HomeFixtures.populated(allowSupport = true, recent = emptyList(), completed = emptyList())
        show(services, support = true)
        compose.onNodeWithText("Don't Ask Again").performClick()
        compose.waitForIdle()
        assertThat(services.engagement.history.value.supportOptedOut).isTrue()
        compose.onNodeWithText("Optional support helps me keep improving Osho Talks.").assertDoesNotExist()
    }
}
