package com.agraabhi.oshodiscourses.feature.player

import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.agraabhi.oshodiscourses.core.domain.denoise.DenoiseState
import com.agraabhi.oshodiscourses.core.domain.player.AudioProcessingStatus
import com.agraabhi.oshodiscourses.core.domain.player.PlaybackError
import com.agraabhi.oshodiscourses.core.domain.sleep.SleepTimerMode
import com.agraabhi.oshodiscourses.core.domain.sleep.SleepTimerState
import com.agraabhi.oshodiscourses.core.model.Appearance
import com.agraabhi.oshodiscourses.core.testing.FakeAppServices
import com.agraabhi.oshodiscourses.core.testing.SampleCatalog
import com.github.takahirom.roborazzi.captureRoboImage
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], qualifiers = "w393dp-h852dp-xxhdpi")
class PlayerScreenScreenshotTest {
    @get:Rule
    val compose = createComposeRule()

    private fun show(services: FakeAppServices, appearance: Appearance = Appearance.LIGHT, fontScale: Float? = null) {
        compose.setContent {
            TestHost(services, appearance, fontScale) {
                PlayerScreen(onDismiss = {}, onOpenTranscript = {}, onOpenSeries = {})
            }
        }
    }

    private fun capture(name: String) = compose.onRoot().captureRoboImage("src/test/screenshots/player_$name.png")

    @Test
    fun playingLight() {
        show(playerServices())
        capture("playing_light")
    }

    @Test
    fun playingDark() {
        show(playerServices(), Appearance.DARK)
        capture("playing_dark")
    }

    @Test
    fun pausedDark() {
        show(playerServices(isPlaying = false), Appearance.DARK)
        capture("paused_dark")
    }

    @Test
    fun bufferingDark() {
        show(playerServices(configure = { copy(isBuffering = true) }), Appearance.DARK)
        capture("buffering_dark")
    }

    @Test
    fun errorLight() {
        val services = playerServices(
            configure = { copy(isPlaying = false, error = PlaybackError("Playback stopped. Try playing the discourse again.")) },
            denoise = DenoiseState(isEnabled = true, status = AudioProcessingStatus.Bypassing),
        )
        show(services)
        capture("error_light")
    }

    /** Speed, sleep and DeNoise all active, with the return-to-position pill. */
    @Test
    fun activeControlsDark() {
        val services = playerServices(
            index = 1,
            configure = { copy(playbackRate = 1.25f, previousPosition = 2_712.0) },
            sleep = SleepTimerState(SleepTimerMode.COUNTDOWN, 872.0),
            denoise = DenoiseState(isEnabled = true, status = AudioProcessingStatus.Active, isProcessorAttached = true),
        )
        show(services, Appearance.DARK)
        capture("active_controls_dark")
    }

    @Test
    fun longTitleLight() {
        show(playerServices(series = LongSeries, index = 11))
        capture("long_title_light")
    }

    @Test
    fun notPlayingLight() {
        show(FakeAppServices())
        capture("not_playing_light")
    }

    @Test
    fun fontScale150() {
        show(playerServices(), fontScale = 1.5f)
        capture("font_150_light")
    }

    @Test
    fun fontScale200Dark() {
        show(playerServices(series = LongSeries), Appearance.DARK, fontScale = 2f)
        capture("font_200_dark")
    }

    @Test
    @Config(qualifiers = "w360dp-h740dp-xxhdpi")
    fun smallPhoneLight() {
        show(playerServices(configure = { copy(previousPosition = 60.0) }))
        capture("small_phone_light")
    }

    @Test
    @Config(qualifiers = "w360dp-h740dp-xxhdpi")
    fun smallPhoneLongTitleDark() {
        show(playerServices(series = LongSeries, configure = { copy(playbackRate = 0.85f) }), Appearance.DARK, fontScale = 1.3f)
        capture("small_phone_long_dark")
    }

    @Test
    fun speedPopoverDark() {
        show(playerServices(configure = { copy(playbackRate = 1.1f) }), Appearance.DARK)
        compose.onNodeWithContentDescription("Playback speed").performClick()
        capture("speed_popover_dark")
    }

    @Test
    fun speedPopoverLight() {
        show(playerServices())
        compose.onNodeWithContentDescription("Playback speed").performClick()
        capture("speed_popover_light")
    }

    @Test
    fun speedPopoverAccessibilitySize() {
        show(playerServices(configure = { copy(playbackRate = 2f) }), fontScale = 2f)
        compose.onNodeWithContentDescription("Playback speed").performClick()
        capture("speed_popover_font_200_light")
    }

    @Test
    fun sleepPopoverLight() {
        show(playerServices(sleep = SleepTimerState(SleepTimerMode.COUNTDOWN, 872.0)))
        compose.onNodeWithContentDescription("Sleep timer").performClick()
        capture("sleep_popover_light")
    }

    @Test
    fun sleepPopoverDark() {
        show(playerServices(), Appearance.DARK)
        compose.onNodeWithContentDescription("Sleep timer").performClick()
        capture("sleep_popover_dark")
    }

    @Test
    fun queueSheetDark() {
        show(playerServices(index = 1), Appearance.DARK)
        compose.onNodeWithContentDescription("Up Next").performClick()
        capture("queue_dark")
    }

    @Test
    fun queueSheetLightPaused() {
        show(playerServices(series = LongSeries, index = 2, isPlaying = false))
        compose.onNodeWithContentDescription("Up Next").performClick()
        capture("queue_paused_light")
    }

    @Test
    fun bookmarkSheetLight() {
        show(playerServices())
        compose.onNodeWithContentDescription("Add bookmark").performClick()
        capture("bookmark_light")
    }

    @Test
    fun bookmarkSheetCustomDark() {
        show(playerServices(), Appearance.DARK)
        compose.onNodeWithContentDescription("Add bookmark").performClick()
        compose.onNodeWithText("Custom").performClick()
        capture("bookmark_custom_dark")
    }

    @Test
    fun bookmarkToastLight() {
        show(playerServices())
        compose.onNodeWithContentDescription("Add bookmark").performClick()
        compose.onNodeWithText("Save").performClick()
        capture("bookmark_toast_light")
    }

    @Test
    fun denoiseSheetDark() {
        show(playerServices(denoise = DenoiseState(isEnabled = true, status = AudioProcessingStatus.Active, isProcessorAttached = true)), Appearance.DARK)
        compose.onNodeWithContentDescription("DeNoise").performClick()
        capture("denoise_sheet_dark")
    }

    @Test
    fun hindiWithoutTranscriptLight() {
        val hindi = queueOf(SampleCatalog.mahaGeeta)
        show(playerServices(series = SampleCatalog.mahaGeeta, configure = { copy(queue = hindi.take(1)) }))
        capture("hindi_no_transcript_light")
    }
}
