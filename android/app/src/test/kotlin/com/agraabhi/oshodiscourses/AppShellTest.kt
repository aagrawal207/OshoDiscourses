package com.agraabhi.oshodiscourses

import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.agraabhi.oshodiscourses.core.model.Appearance
import com.agraabhi.oshodiscourses.core.testing.FakeAppServices
import com.agraabhi.oshodiscourses.core.testing.SampleCatalog
import com.agraabhi.oshodiscourses.core.ui.LocalAppServices
import com.agraabhi.oshodiscourses.core.ui.theme.OshoTheme
import com.agraabhi.oshodiscourses.navigation.AppShell
import com.github.takahirom.roborazzi.captureRoboImage
import com.google.common.truth.Truth.assertThat
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], qualifiers = "w393dp-h852dp-xxhdpi")
class AppShellTest {
    @get:Rule
    val compose = createComposeRule()

    private val services = FakeAppServices()

    private fun launch(appearance: Appearance = Appearance.LIGHT) {
        compose.setContent {
            CompositionLocalProvider(LocalAppServices provides services) {
                OshoTheme(appearance = appearance) { AppShell() }
            }
        }
        // Let the launch overlay fade out.
        compose.mainClock.advanceTimeBy(1_000)
    }

    private fun tab(title: String) = compose.onNode(hasText(title) and SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.Tab))

    @Test
    fun tabsAppearInIosOrderWithHomeSelected() {
        launch()
        val tabs = compose.onAllNodes(SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.Tab)).fetchSemanticsNodes()
        assertThat(tabs.map { it.config[SemanticsProperties.Text].joinToString() }).containsExactly("Home", "Library", "Downloads", "Settings").inOrder()
        tab("Home").assertIsSelected()
    }

    @Test
    fun seriesPushesFromHomeAndPlayingOpensThePlayerModal() {
        launch()
        compose.onNodeWithText(SampleCatalog.birdOnTheWing.name).performClick()
        compose.onNodeWithText(SampleCatalog.firstDiscourse.displayTitle).performClick()
        compose.waitForIdle()
        assertThat(services.player.state.value.currentTrackId).isEqualTo(SampleCatalog.firstDiscourse.id)
        compose.onNodeWithText("Close").performClick()
        compose.mainClock.advanceTimeBy(1_000)
        // The mini-player shows the discourse number above the series.
        compose.onNodeWithText("Discourse 1").assertExists()
        compose.onRoot().captureRoboImage("src/test/screenshots/app_shell_mini_player_light.png")
    }

    @Test
    fun eachTabKeepsItsOwnBackStack() {
        launch()
        compose.onNodeWithText(SampleCatalog.mahaGeeta.name).performClick()
        compose.onNodeWithText(SampleCatalog.hindiDiscourse.displayTitle).assertExists()
        tab("Library").performClick()
        tab("Library").assertIsSelected()
        compose.onNodeWithText(SampleCatalog.hindiDiscourse.displayTitle).assertDoesNotExist()
        tab("Home").performClick()
        compose.onNodeWithText(SampleCatalog.hindiDiscourse.displayTitle).assertExists()
    }

    @Test
    fun shellDark() {
        launch(Appearance.DARK)
        compose.onRoot().captureRoboImage("src/test/screenshots/app_shell_home_dark.png")
    }
}
