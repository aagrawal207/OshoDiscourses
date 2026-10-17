package com.agraabhi.oshodiscourses.feature.library

import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToIndex
import androidx.compose.ui.test.performScrollToKey
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.agraabhi.oshodiscourses.core.model.Appearance
import com.agraabhi.oshodiscourses.core.model.LanguageFilter
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
class LibraryScreenScreenshotTest {
    @get:Rule
    val compose = createComposeRule()

    private fun show(services: FakeAppServices, appearance: Appearance = Appearance.LIGHT, fontScale: Float = 1f) {
        compose.setContent { TestHost(services, appearance, fontScale) { LibraryScreen(onOpenSeries = {}) } }
    }

    private fun capture(name: String) = compose.onRoot().captureRoboImage("src/test/screenshots/$name.png")

    @Test
    fun allLight() {
        show(LibraryFixtures.withDownloads())
        capture("library_all_light")
    }

    @Test
    fun allDark() {
        show(LibraryFixtures.withDownloads(), Appearance.DARK)
        capture("library_all_dark")
    }

    @Test
    fun hindiOnlyHidesLanguageChips() {
        show(LibraryFixtures.services(language = LanguageFilter.HINDI))
        capture("library_hindi_only_light")
    }

    @Test
    fun sortMenuDark() {
        show(LibraryFixtures.withDownloads(), Appearance.DARK)
        compose.onNodeWithTag(FILTER_BAR_TAG).performScrollToKey("sort")
        compose.onNodeWithContentDescription("Sort").performClick()
        compose.waitForIdle()
        captureScreenRoboImage("src/test/screenshots/library_sort_menu_dark.png")
    }

    @Test
    fun themeChipActiveLight() {
        show(LibraryFixtures.withDownloads())
        compose.onNodeWithTag(FILTER_BAR_TAG).performScrollToKey("Meditation")
        compose.onNode(androidx.compose.ui.test.hasText("Meditation")).performClick()
        capture("library_theme_active_light")
    }

    @Test
    fun searchingLight() {
        show(LibraryFixtures.withDownloads())
        compose.onNodeWithContentDescription("Search by name or topic").performTextInput("zen")
        capture("library_search_light")
    }

    @Test
    fun noResultsLight() {
        show(LibraryFixtures.withDownloads())
        compose.onNodeWithContentDescription("Search by name or topic").performTextInput("xyzzy")
        capture("library_no_results_light")
    }

    @Test
    fun noResultsDark() {
        show(LibraryFixtures.withDownloads(), Appearance.DARK)
        compose.onNodeWithContentDescription("Search by name or topic").performTextInput("xyzzy")
        capture("library_no_results_dark")
    }

    @Test
    fun emptyCatalogLight() {
        show(LibraryFixtures.services(catalog = emptyList()))
        capture("library_empty_light")
    }

    @Test
    fun fontScale150() {
        show(LibraryFixtures.withDownloads(), fontScale = 1.5f)
        capture("library_font150_light")
    }

    @Test
    fun fontScale200() {
        show(LibraryFixtures.withDownloads(), Appearance.DARK, fontScale = 2f)
        capture("library_font200_dark")
    }

    @Test
    @Config(qualifiers = "w360dp-h740dp-xxhdpi")
    fun smallPhone() {
        show(LibraryFixtures.withDownloads())
        capture("library_small_phone_light")
    }

    @Test
    fun collapsedTitleLight() {
        show(LibraryFixtures.withDownloads())
        compose.onNodeWithTag(LARGE_TITLE_LIST_TAG).performScrollToIndex(3)
        capture("library_collapsed_title_light")
    }
}
