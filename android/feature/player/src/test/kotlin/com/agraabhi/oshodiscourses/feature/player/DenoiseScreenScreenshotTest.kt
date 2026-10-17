package com.agraabhi.oshodiscourses.feature.player

import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.agraabhi.oshodiscourses.core.domain.denoise.DenoiseState
import com.agraabhi.oshodiscourses.core.domain.player.AudioProcessingStatus
import com.agraabhi.oshodiscourses.core.domain.player.DeepFilterStatus
import com.agraabhi.oshodiscourses.core.model.Appearance
import com.agraabhi.oshodiscourses.core.model.DenoiseStrength
import com.agraabhi.oshodiscourses.core.model.NoiseReductionMode
import com.agraabhi.oshodiscourses.core.testing.FakeAppServices
import com.agraabhi.oshodiscourses.core.testing.FakeDenoiseController
import com.agraabhi.oshodiscourses.core.ui.theme.ProvideElevatedSurfaces
import com.github.takahirom.roborazzi.captureRoboImage
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], qualifiers = "w393dp-h852dp-xxhdpi")
class DenoiseScreenScreenshotTest {
    @get:Rule
    val compose = createComposeRule()

    private val active = DenoiseState(isEnabled = true, status = AudioProcessingStatus.Active, isProcessorAttached = true)

    private fun show(state: DenoiseState, appearance: Appearance = Appearance.LIGHT, fontScale: Float? = null, inSheet: Boolean = false) {
        val services = FakeAppServices(denoise = FakeDenoiseController(state))
        compose.setContent {
            TestHost(services, appearance, fontScale) {
                if (inSheet) {
                    ProvideElevatedSurfaces { DenoiseScreen(onDone = {}) }
                } else {
                    DenoiseScreen(onBack = {})
                }
            }
        }
    }

    private fun capture(name: String) = compose.onRoot().captureRoboImage("src/test/screenshots/denoise_$name.png")

    @Test
    fun offLight() {
        show(DenoiseState())
        capture("off_light")
    }

    @Test
    fun offDark() {
        show(DenoiseState(), Appearance.DARK)
        capture("off_dark")
    }

    @Test
    fun activeLight() {
        show(active)
        capture("active_light")
    }

    @Test
    fun activeSheetDark() {
        show(active.copy(strength = DenoiseStrength.STRONG, boostGain = 3f), Appearance.DARK, inSheet = true)
        capture("active_sheet_dark")
    }

    @Test
    fun preparingBalancedLight() {
        show(DenoiseState(isEnabled = true, mode = NoiseReductionMode.RNNOISE, status = AudioProcessingStatus.Preparing))
        capture("preparing_balanced_light")
    }

    @Test
    fun issueDark() {
        show(
            DenoiseState(isEnabled = true, status = AudioProcessingStatus.ModelUnavailable(DeepFilterStatus.InitializationFailed), boostGain = 1.5f),
            Appearance.DARK,
        )
        capture("issue_dark")
    }

    @Test
    fun waitingForPlaybackBoostOffLight() {
        show(DenoiseState(isEnabled = true, status = AudioProcessingStatus.WaitingForPlayback, boostGain = 1f))
        capture("waiting_boost_off_light")
    }

    @Test
    fun accessibilitySizeLight() {
        show(active, fontScale = 2f)
        capture("font_200_light")
    }

    @Test
    fun fontScale150Dark() {
        show(active, Appearance.DARK, fontScale = 1.5f)
        capture("font_150_dark")
    }

    @Test
    @Config(qualifiers = "w360dp-h740dp-xxhdpi")
    fun smallPhoneLight() {
        show(active)
        capture("small_phone_light")
    }

    @Test
    fun listeningModeLight() {
        show(active)
        compose.onNodeWithContentDescription("Listening mode").performClick()
        capture("listening_mode_light")
    }

    @Test
    fun listeningModeDark() {
        show(active.copy(mode = NoiseReductionMode.CADENCE), Appearance.DARK)
        compose.onNodeWithContentDescription("Listening mode").performClick()
        capture("listening_mode_dark")
    }

    @Test
    fun quietSpeechDark() {
        show(active, Appearance.DARK)
        compose.onNodeWithText("Fine-tune the voice").performClick()
        capture("quiet_speech_dark")
    }
}
