package com.agraabhi.oshodiscourses.feature.transcript

import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.agraabhi.oshodiscourses.core.domain.player.PlayerState
import com.agraabhi.oshodiscourses.core.domain.settings.UserSettings
import com.agraabhi.oshodiscourses.core.domain.transcript.Transcript
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptAnchor
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptDiscourseState
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptException
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptReadPosition
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptRepository
import com.agraabhi.oshodiscourses.core.model.Appearance
import com.agraabhi.oshodiscourses.core.testing.FakeAppServices
import com.agraabhi.oshodiscourses.core.testing.FakeSettingsRepository
import com.agraabhi.oshodiscourses.core.testing.FakeTranscriptStateRepository
import com.agraabhi.oshodiscourses.core.ui.LocalAppServices
import com.agraabhi.oshodiscourses.core.ui.theme.OshoTheme
import com.agraabhi.oshodiscourses.core.ui.theme.ProvideElevatedSurfaces
import com.github.takahirom.roborazzi.ExperimentalRoborazziApi
import com.github.takahirom.roborazzi.captureRoboImage
import com.github.takahirom.roborazzi.captureScreenRoboImage
import com.google.common.truth.Truth.assertThat
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], qualifiers = "w393dp-h852dp-xxhdpi")
@OptIn(ExperimentalRoborazziApi::class)
class TranscriptScreenScreenshotTest {
    @get:Rule
    val compose = createComposeRule()

    private val english = TranscriptFixtures.englishTranscript
    private val hindi = TranscriptFixtures.hindiTranscript

    private fun show(
        appearance: Appearance = Appearance.LIGHT,
        transcript: Transcript = english,
        playing: Boolean = true,
        time: Double = 260.0,
        settings: UserSettings = UserSettings(),
        aligned: Boolean = false,
        repository: TranscriptRepository = ModelTimingRepository(TranscriptFixtures.repository(), aligned = aligned),
        state: TranscriptDiscourseState? = null,
        pageURL: String? = "https://www.oshoworld.com/example",
    ): TranscriptViewModel {
        val services = FakeAppServices(settings = FakeSettingsRepository(settings))
        if (playing) {
            services.player.state.value = PlayerState(
                currentTrackId = transcript.discourseID,
                currentTitle = "",
                currentSeries = "",
                isPlaying = true,
                currentTime = time,
                duration = 1_000.0,
            )
        }
        val states = FakeTranscriptStateRepository(state?.let { mapOf(transcript.discourseID to it) } ?: emptyMap())
        val vm = TranscriptViewModel(transcript.discourseID, services.catalog, repository, states, services.player, services.settings)
        compose.setContent {
            CompositionLocalProvider(LocalAppServices provides services) {
                OshoTheme(appearance = appearance) {
                    ProvideElevatedSurfaces { TranscriptContentScreen(vm, onDismiss = {}, pageURL = pageURL) }
                }
            }
        }
        compose.runOnIdle { vm.start() }
        compose.waitForIdle()
        return vm
    }

    private fun capture(name: String) = compose.onRoot().captureRoboImage("src/test/screenshots/transcript_$name.png")

    private fun captureScreen(name: String) = captureScreenRoboImage("src/test/screenshots/transcript_$name.png")

    @Test
    fun readerLight() {
        show()
        capture("reader_light")
    }

    @Test
    fun readerDark() {
        show(Appearance.DARK)
        capture("reader_dark")
    }

    @Test
    fun blocksWithSentenceHighlightDark() {
        show(Appearance.DARK, time = 330.0, aligned = true, settings = UserSettings(transcriptSentenceLayout = false))
        capture("blocks_aligned_dark")
    }

    @Test
    fun hindiLight() {
        show(transcript = hindi, time = 520.0, aligned = true, settings = UserSettings(transcriptSentenceLayout = false))
        capture("hindi_light")
    }

    @Test
    fun hindiSentencesDark() {
        show(Appearance.DARK, transcript = hindi, time = 300.0)
        capture("hindi_sentences_dark")
    }

    @Test
    fun nowPlayingPill() {
        val vm = show(time = 900.0, state = TranscriptDiscourseState(readPosition = TranscriptReadPosition(1, 1), paragraphCount = english.paragraphs.size))
        assertThat(vm.state.value.showsNowPlaying).isTrue()
        capture("now_playing_pill")
    }

    @Test
    fun searchActive() {
        val vm = show()
        compose.onNodeWithContentDescription("Search transcript").performClick()
        compose.runOnIdle { vm.setSearchQuery("river") }
        compose.waitForIdle()
        assertThat(vm.state.value.searchCounter).startsWith("1/")
        capture("search_light")
    }

    @Test
    fun actionBarForATappedRow() {
        val vm = show()
        val row = vm.state.value.rows[vm.state.value.currentOrdinal!! + 1]
        compose.onNodeWithText(row.text).performClick()
        compose.waitForIdle()
        compose.onNodeWithText("Audio is here").assertExists()
        capture("action_bar")
    }

    @Test
    fun actionBarDark() {
        val vm = show(Appearance.DARK)
        val row = vm.state.value.rows[vm.state.value.currentOrdinal!!]
        compose.onNodeWithText(row.text).performClick()
        compose.waitForIdle()
        capture("action_bar_dark")
    }

    @Test
    fun longPressMenu() {
        val vm = show()
        val row = vm.state.value.rows[vm.state.value.currentOrdinal!! + 2]
        compose.onNodeWithText(row.text).performTouchInput { longClick(center) }
        compose.waitForIdle()
        compose.onNodeWithText("Select Passages").assertExists()
        captureScreen("long_press_menu")
    }

    @Test
    fun passageSelection() {
        val vm = show()
        val rows = vm.state.value.rows
        compose.runOnIdle {
            vm.startSelecting(rows[3])
            vm.selectUpToHere(rows[5])
        }
        compose.waitForIdle()
        compose.onNodeWithText("3 selected").assertExists()
        capture("selecting")
    }

    @Test
    fun selectionModeMenuOffersSelectUpToHere() {
        val vm = show(Appearance.DARK)
        val rows = vm.state.value.rows
        compose.runOnIdle { vm.startSelecting(rows[3]) }
        compose.waitForIdle()
        compose.onNodeWithText(rows[6].text).performTouchInput { longClick(center) }
        compose.waitForIdle()
        compose.onNodeWithText("Select Up to Here").assertExists()
        captureScreen("selecting_menu_dark")
    }

    @Test
    fun smallestFont() {
        show(settings = UserSettings(transcriptFontSize = 15.0))
        capture("font_15")
    }

    @Test
    fun largestFont() {
        show(Appearance.DARK, settings = UserSettings(transcriptFontSize = 28.0))
        capture("font_28_dark")
    }

    @Test
    @Config(qualifiers = "w360dp-h740dp-xxhdpi")
    fun smallPhone() {
        show()
        capture("small_phone")
    }

    @Test
    @Config(qualifiers = "w360dp-h740dp-xxhdpi")
    fun smallPhoneSearch() {
        val vm = show(Appearance.DARK)
        compose.onNodeWithContentDescription("Search transcript").performClick()
        compose.runOnIdle { vm.setSearchQuery("the") }
        compose.waitForIdle()
        capture("small_phone_search_dark")
    }

    @Test
    fun optionsMenu() {
        show(state = TranscriptDiscourseState(anchors = listOf(TranscriptAnchor(2, 120.0, 1), TranscriptAnchor(6, 600.0, 2)), paragraphCount = english.paragraphs.size))
        compose.onNodeWithContentDescription("Transcript options").performClick()
        compose.waitForIdle()
        compose.onNodeWithText("Clear 2 sync anchors").assertExists()
        captureScreen("options_menu")
    }

    @Test
    fun notPlayingThisDiscourse() {
        show(Appearance.DARK, playing = false)
        capture("not_playing_dark")
    }

    @Test
    fun loading() {
        show(repository = ModelTimingRepository(TranscriptFixtures.repository(), hangs = true))
        capture("loading")
    }

    @Test
    fun networkError() {
        show(repository = TranscriptFixtures.repository(failure = TranscriptException.Network("The Internet connection appears to be offline.")))
        compose.onNodeWithText("Try Again").assertExists()
        capture("error_network")
    }

    @Test
    fun siteErrorDark() {
        show(Appearance.DARK, repository = TranscriptFixtures.repository(failure = TranscriptException.Blank()))
        compose.onNodeWithText("Try Again").assertDoesNotExist()
        capture("error_blank_dark")
    }

    @Test
    fun noTranscript() {
        show(repository = com.agraabhi.oshodiscourses.core.testing.FakeTranscriptRepository(transcripts = emptyMap()), playing = false)
        compose.onNodeWithText("No transcript yet").assertExists()
        capture("none")
    }

    @Test
    fun selectTextScreen() {
        val vm = show()
        val rows = vm.state.value.rows
        compose.runOnIdle { vm.openTextSelection(rows.subList(1, 5)) }
        compose.waitForIdle()
        capture("select_text")
    }

    @Test
    fun copyToast() {
        val vm = show(Appearance.DARK)
        compose.runOnIdle { vm.copy(vm.state.value.rows.subList(0, 2)) }
        compose.waitForIdle()
        compose.onNodeWithText("Copied 2 passages").assertExists()
        capture("toast_dark")
    }
}
