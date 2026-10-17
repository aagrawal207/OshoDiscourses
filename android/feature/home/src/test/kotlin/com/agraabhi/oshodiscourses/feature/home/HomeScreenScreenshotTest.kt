package com.agraabhi.oshodiscourses.feature.home

import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performScrollToIndex
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.agraabhi.oshodiscourses.core.model.Appearance
import com.agraabhi.oshodiscourses.core.model.LanguageFilter
import com.agraabhi.oshodiscourses.core.testing.FakeAppServices
import com.agraabhi.oshodiscourses.core.ui.components.LARGE_TITLE_LIST_TAG
import com.github.takahirom.roborazzi.captureRoboImage
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], qualifiers = "w393dp-h852dp-xxhdpi")
class HomeScreenScreenshotTest {
    @get:Rule
    val compose = createComposeRule()

    private fun show(services: FakeAppServices, appearance: Appearance = Appearance.LIGHT, fontScale: Float = 1f, support: Boolean = false) {
        compose.setContent {
            TestHost(services, appearance, fontScale) {
                HomeScreen(onOpenSeries = {}, onOpenSupport = if (support) ({ _ -> }) else null)
            }
        }
    }

    private fun capture(name: String) = compose.onRoot().captureRoboImage("src/test/screenshots/$name.png")

    @Test
    fun populatedLight() {
        show(HomeFixtures.populated())
        capture("home_populated_light")
    }

    @Test
    fun populatedDark() {
        show(HomeFixtures.populated(), Appearance.DARK)
        capture("home_populated_dark")
    }

    @Test
    fun shelvesBelowTheFoldLight() {
        show(HomeFixtures.populated())
        compose.onNodeWithTag(LARGE_TITLE_LIST_TAG).performScrollToIndex(3)
        capture("home_shelves_scrolled_light")
    }

    @Test
    fun newUserLight() {
        show(HomeFixtures.newUser())
        capture("home_new_user_light")
    }

    @Test
    fun newUserDark() {
        show(HomeFixtures.newUser(), Appearance.DARK)
        capture("home_new_user_dark")
    }

    @Test
    fun englishOnlyDark() {
        show(HomeFixtures.populated(language = LanguageFilter.ENGLISH), Appearance.DARK)
        compose.onNodeWithTag(LARGE_TITLE_LIST_TAG).performScrollToIndex(3)
        capture("home_english_only_dark")
    }

    @Test
    fun longTitlesLight() {
        show(HomeFixtures.longTitles())
        capture("home_long_titles_light")
    }

    @Test
    fun supportCardLight() {
        show(HomeFixtures.populated(allowSupport = true, recent = emptyList(), completed = emptyList()), support = true)
        capture("home_support_card_light")
    }

    @Test
    fun supportCardLargeTextDark() {
        show(HomeFixtures.populated(allowSupport = true, recent = emptyList(), completed = emptyList()), Appearance.DARK, fontScale = 2f, support = true)
        capture("home_support_card_font200_dark")
    }

    @Test
    fun fontScale150() {
        show(HomeFixtures.populated(), fontScale = 1.5f)
        capture("home_font150_light")
    }

    @Test
    fun fontScale200() {
        show(HomeFixtures.populated(), Appearance.DARK, fontScale = 2f)
        capture("home_font200_dark")
    }

    @Test
    @Config(qualifiers = "w360dp-h740dp-xxhdpi")
    fun smallPhone() {
        show(HomeFixtures.longTitles())
        capture("home_small_phone_light")
    }

    @Test
    fun collapsedTitleLight() {
        show(HomeFixtures.populated())
        compose.onNodeWithTag(LARGE_TITLE_LIST_TAG).performScrollToIndex(2)
        capture("home_collapsed_title_light")
    }
}
