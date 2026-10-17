package com.agraabhi.oshodiscourses

import android.os.Looper
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasScrollToNodeAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTouchInput
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.agraabhi.oshodiscourses.core.domain.AppServices
import com.agraabhi.oshodiscourses.core.domain.player.PlayerController
import com.agraabhi.oshodiscourses.core.domain.progress.PlaybackProgress
import com.agraabhi.oshodiscourses.core.model.Appearance
import com.agraabhi.oshodiscourses.core.testing.FakeAppServices
import com.agraabhi.oshodiscourses.core.testing.FakeDownloadManager
import com.agraabhi.oshodiscourses.core.testing.FakePlaybackStateRepository
import com.agraabhi.oshodiscourses.core.testing.SampleCatalog
import com.agraabhi.oshodiscourses.core.ui.LocalAppServices
import com.agraabhi.oshodiscourses.core.ui.theme.OshoTheme
import com.agraabhi.oshodiscourses.denoise.DenoiseEngine
import com.agraabhi.oshodiscourses.navigation.AppShell
import com.agraabhi.oshodiscourses.playback.PlaybackEngine
import com.github.takahirom.roborazzi.captureRoboImage
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], qualifiers = "w393dp-h852dp-xxhdpi")
class AppShellTest {
    @get:Rule
    val compose = createComposeRule()

    private val services = FakeAppServices(downloads = FakeDownloadManager(downloaded = setOf(SampleCatalog.firstDiscourse.id)))

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

    /** The mini-player merges its lines into one button that opens the full player. */
    private fun miniPlayer() = compose.onNode(
        SemanticsMatcher("mini-player") { it.config.getOrElseNullable(SemanticsActions.OnClick) { null }?.label == "open the full player" },
    )

    /** Home lists a series on more than one shelf; any of them opens it. */
    private fun openFromHome(name: String) = compose.onAllNodesWithText(name).onFirst().performClick()

    @Test
    fun seriesRowPlaysIntoTheMiniPlayerWithoutOpeningThePlayer() {
        launch()
        openFromHome(SampleCatalog.birdOnTheWing.name)
        compose.onNodeWithContentDescription("Discourse 1", substring = true).performClick()
        compose.mainClock.advanceTimeBy(1_000)
        assertThat(services.player.state.value.currentTrackId).isEqualTo(SampleCatalog.firstDiscourse.id)
        // As on iOS, a row tap starts playback and shows only the mini-player.
        compose.onNodeWithText("Close").assertDoesNotExist()
        miniPlayer().assertExists()
        compose.onRoot().captureRoboImage("src/test/screenshots/app_shell_mini_player_light.png")
    }

    /** The production engine over the fakes; a restore never builds its player, so no audio is involved. */
    private fun restoringServices(): Pair<AppServices, PlaybackEngine> {
        val first = SampleCatalog.firstDiscourse
        val fakes = FakeAppServices(
            downloads = FakeDownloadManager(downloaded = setOf(first.id)),
            playbackState = FakePlaybackStateRepository(
                PlaybackProgress(positions = mapOf(first.id to 754.0), durations = mapOf(first.id to 5_400.0), recentlyPlayed = listOf(first.id)),
            ),
        )
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val engine = PlaybackEngine.create(
            context = ApplicationProvider.getApplicationContext(),
            catalog = fakes.catalog,
            downloads = fakes.downloads,
            bookmarks = fakes.bookmarks,
            settings = fakes.settings,
            playbackState = fakes.playbackState,
            listeningStats = fakes.listeningStats,
            sleepTimer = fakes.sleepTimer,
            pipeline = DenoiseEngine.create(ApplicationProvider.getApplicationContext(), fakes.settings, scope),
            scope = scope,
        )
        return object : AppServices by fakes {
            override val player: PlayerController = engine
        } to engine
    }

    @Test
    fun aRestoredTalkShowsPausedInTheMiniPlayerAndTheFullPlayer() {
        val (restoring, engine) = restoringServices()
        var restored: Boolean? = null
        CoroutineScope(Dispatchers.Main.immediate).launch { restored = engine.restoreLastSession() }
        // The file checks run on Dispatchers.IO and post the load back to the paused main looper.
        val deadline = System.currentTimeMillis() + 5_000
        while (restored == null && System.currentTimeMillis() < deadline) {
            shadowOf(Looper.getMainLooper()).idle()
            Thread.sleep(5)
        }
        assertThat(restored).isTrue()
        compose.setContent {
            CompositionLocalProvider(LocalAppServices provides restoring) {
                OshoTheme(appearance = Appearance.LIGHT) { AppShell() }
            }
        }
        compose.mainClock.advanceTimeBy(1_000)

        miniPlayer().assertExists().assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Paused"))
        compose.onNodeWithContentDescription("Play").assertExists()
        compose.onNodeWithText("Close").assertDoesNotExist()

        miniPlayer().performClick()
        compose.mainClock.advanceTimeBy(1_000)
        compose.onNodeWithContentDescription("Playback position")
            .assert(SemanticsMatcher("at the saved position") { it.config.getOrElseNullable(SemanticsProperties.StateDescription) { null }?.startsWith("12:34 of") == true })
        compose.onNodeWithContentDescription("Skip back 15 seconds").assertExists()
        compose.onAllNodes(hasContentDescription("Play") and hasClickAction()).fetchSemanticsNodes().let { assertThat(it).isNotEmpty() }
        compose.onNode(hasContentDescription("Pause")).assertDoesNotExist()
        assertThat(engine.state.value.isPlaying).isFalse()
    }

    @Test
    fun seriesMenuBookmarksTheCurrentTrackInAWindowSheet() {
        launch()
        openFromHome(SampleCatalog.birdOnTheWing.name)
        compose.onNodeWithContentDescription("Discourse 1", substring = true).performClick()
        compose.mainClock.advanceTimeBy(1_000)
        compose.onAllNodesWithContentDescription("Discourse 1", substring = true).onFirst().performTouchInput { longClick(center) }
        compose.onNodeWithText("Add Bookmark…").performClick()
        compose.mainClock.advanceTimeBy(1_000)
        // The sheet opens over the series; the full player stays closed, as on iOS.
        compose.onNodeWithText("Close").assertDoesNotExist()
        compose.onNodeWithText("Save").performClick()
        compose.mainClock.advanceTimeBy(1_000)
        assertThat(services.bookmarks.bookmarks.value.map { it.discourseID }).containsExactly(SampleCatalog.firstDiscourse.id)
        compose.onNodeWithText("Add Bookmark").assertDoesNotExist()
    }

    @Test
    fun downloadsPushesStatsThenHistoryAndBackReturns() {
        launch()
        tab("Downloads").performClick()
        compose.onNode(hasText("Listening Stats") and hasClickAction()).performScrollTo().performClick()
        compose.onNodeWithText("Full Listening History").performScrollTo().performClick()
        compose.onNodeWithContentDescription("Back").performClick()
        compose.onNodeWithText("Full Listening History").assertExists()
        compose.onNodeWithContentDescription("Back").performClick()
        compose.onNodeWithContentDescription("Back").assertDoesNotExist()
    }

    @Test
    fun settingsSupportRowOpensTheSupportSheet() {
        launch()
        tab("Settings").performClick()
        compose.onNode(hasScrollToNodeAction()).performScrollToNode(hasText("Support Development"))
        compose.onNode(hasText("Support Development") and hasClickAction()).performClick()
        compose.mainClock.advanceTimeBy(1_000)
        compose.onNodeWithText("Small tip", substring = true).assertExists()
    }

    @Test
    fun eachTabKeepsItsOwnBackStack() {
        launch()
        compose.onNodeWithContentDescription("Back").assertDoesNotExist()
        openFromHome(SampleCatalog.mahaGeeta.name)
        compose.onNodeWithContentDescription("Back").assertExists()
        tab("Library").performClick()
        tab("Library").assertIsSelected()
        compose.onNodeWithContentDescription("Back").assertDoesNotExist()
        tab("Home").performClick()
        compose.onNodeWithContentDescription("Back").assertExists()
        compose.onNodeWithContentDescription("Back").performClick()
        compose.onNodeWithContentDescription("Back").assertDoesNotExist()
    }

    @Test
    fun shellDark() {
        launch(Appearance.DARK)
        compose.onRoot().captureRoboImage("src/test/screenshots/app_shell_home_dark.png")
    }
}
