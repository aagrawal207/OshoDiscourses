package com.agraabhi.oshodiscourses.feature.library

import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.assertIsNotSelected
import androidx.compose.ui.test.hasStateDescription
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTextClearance
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performScrollToKey
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.agraabhi.oshodiscourses.core.testing.FakeAppServices
import com.google.common.truth.Truth.assertThat
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [36], qualifiers = "w393dp-h852dp-xxhdpi")
class LibraryScreenInteractionTest {
    @get:Rule
    val compose = createComposeRule()

    private var opened: String? = null

    private fun chip(label: String) = compose.onNode(hasText(label).and(SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.Tab)))

    private fun revealSort() = compose.onNodeWithTag(FILTER_BAR_TAG).performScrollToKey("sort")

    private fun show(services: FakeAppServices = LibraryFixtures.withDownloads()) {
        compose.setContent { TestHost(services) { LibraryScreen(onOpenSeries = { opened = it }) } }
    }

    @Test
    fun tappingARowOpensTheSeries() {
        show()
        compose.onNodeWithText(LibraryFixtures.ahThis.name).performClick()
        assertThat(opened).isEqualTo(LibraryFixtures.ahThis.id)
    }

    @Test
    fun aChipFiltersAndTappingItAgainReturnsToAll() {
        show()
        chip("Hindi").performClick()
        chip("Hindi").assertIsSelected()
        compose.onNodeWithText(LibraryFixtures.bird.name).assertDoesNotExist()
        compose.onNodeWithText(LibraryFixtures.agyat.name).assertIsDisplayed()

        chip("Hindi").performClick()
        chip("All").assertIsSelected()
        compose.onNodeWithText(LibraryFixtures.bird.name).assertIsDisplayed()
    }

    @Test
    fun downloadedFilterShowsSeriesWithADownload() {
        show()
        chip("Downloaded").performClick()
        compose.onNodeWithText(LibraryFixtures.bird.name).assertIsDisplayed()
        compose.onNodeWithText(LibraryFixtures.ajhun.name).assertIsDisplayed()
        compose.onNodeWithText(LibraryFixtures.thunder.name).assertDoesNotExist()
    }

    @Test
    fun theDownloadedChipDisappearsWithTheLastDownloadAndTheFilterFallsBack() {
        val services = LibraryFixtures.withDownloads()
        show(services)
        chip("Downloaded").performClick()
        services.downloads.setState("${LibraryFixtures.bird.id}-1", com.agraabhi.oshodiscourses.core.domain.downloads.DownloadState.NotDownloaded)
        services.downloads.setState("${LibraryFixtures.ajhun.id}-3", com.agraabhi.oshodiscourses.core.domain.downloads.DownloadState.NotDownloaded)
        compose.waitForIdle()
        chip("Downloaded").assertDoesNotExist()
        chip("All").assertIsSelected()
        compose.onNodeWithText(LibraryFixtures.thunder.name).assertIsDisplayed()
    }

    @Test
    fun searchMatchesDescriptionsAndThemes() {
        show()
        compose.onNodeWithContentDescription("Search by name or topic").performTextInput("KABIR")
        compose.onNodeWithText(LibraryFixtures.ajhun.name).assertIsDisplayed()
        compose.onNodeWithText(LibraryFixtures.bird.name).assertDoesNotExist()
        compose.onNodeWithContentDescription("Clear text").performClick()
        compose.onNodeWithText(LibraryFixtures.bird.name).assertIsDisplayed()
    }

    @Test
    fun noResultsOnlyWhileSearching() {
        show()
        compose.onNodeWithContentDescription("Search by name or topic").performTextInput("xyzzy")
        compose.onNodeWithText("No Results for “xyzzy”").assertIsDisplayed()
        compose.onNodeWithText("Check the spelling or try a new search.").assertIsDisplayed()
    }

    @Test
    fun sortMenuFlipsTheCurrentFieldAndStartsANewOneAscending() {
        show()
        revealSort()
        compose.onNode(hasContentDescription("Sort").and(hasStateDescription("Name, ascending"))).performClick()
        compose.onNode(hasText("Name").and(androidx.compose.ui.test.hasClickAction()).and(hasContentDescription("Sort").not())).performClick()
        compose.onNode(hasContentDescription("Sort").and(hasStateDescription("Name, descending"))).assertExists()
        compose.onNodeWithContentDescription("Sort").performClick()
        compose.onNode(hasText("Episodes").and(hasContentDescription("Sort").not())).performClick()
        compose.onNode(hasContentDescription("Sort").and(hasStateDescription("Episodes, ascending"))).assertExists()
    }
}
