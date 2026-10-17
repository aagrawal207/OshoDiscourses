package com.agraabhi.oshodiscourses.feature.player

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.onAllNodesWithText
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.agraabhi.oshodiscourses.core.domain.denoise.DenoiseState
import com.agraabhi.oshodiscourses.core.domain.player.AudioProcessingStatus
import com.agraabhi.oshodiscourses.core.model.DenoiseStrength
import com.agraabhi.oshodiscourses.core.model.NoiseReductionMode
import com.agraabhi.oshodiscourses.core.model.VoiceFocusPreset
import com.agraabhi.oshodiscourses.core.testing.FakeAppServices
import com.agraabhi.oshodiscourses.core.testing.FakeDenoiseController
import com.google.common.truth.Truth.assertThat
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [36], qualifiers = "w393dp-h852dp-xxhdpi")
class DenoiseScreenInteractionTest {
    @get:Rule
    val compose = createComposeRule()

    private lateinit var denoise: FakeDenoiseController
    private var backs = 0

    private fun show(initial: DenoiseState = DenoiseState()) {
        denoise = FakeDenoiseController(initial)
        compose.setContent {
            TestHost(FakeAppServices(denoise = denoise)) { DenoiseScreen(onBack = { backs++ }) }
        }
    }

    private val state get() = denoise.state.value

    @Test
    fun enablingShowsTheNoiseAndVoiceSections() {
        show()
        compose.onNodeWithText("Noise Reduction").assertDoesNotExist()
        compose.onNodeWithText("Turn on DeNoise to use volume boost. It raises the volume after reducing noise.").assertIsDisplayed()
        compose.onNodeWithText("Enable DeNoise").performClick()
        assertThat(state.isEnabled).isTrue()
        compose.onNodeWithText("Noise Reduction").assertIsDisplayed()
        compose.onNodeWithText("Enhancement is on").assertIsDisplayed()
        compose.onNodeWithText("Fine-tune the voice").assertIsDisplayed()
    }

    @Test
    fun boostIsDisabledWhileOff() {
        show()
        compose.onNodeWithText("Max").assertIsNotEnabled()
    }

    @Test
    fun strengthAndBoostApply() {
        show(DenoiseState(isEnabled = true, status = AudioProcessingStatus.Active, isProcessorAttached = true))
        compose.onNodeWithText("Strong").performClick()
        assertThat(state.strength).isEqualTo(DenoiseStrength.STRONG)
        compose.onNodeWithText("More noise reduction. The voice may sound less natural.").assertIsDisplayed()
        compose.onNodeWithText("High").performClick()
        assertThat(state.boostGain).isEqualTo(3f)
        compose.onNodeWithText("Off").performClick()
        assertThat(state.boostGain).isEqualTo(1f)
        compose.onNodeWithText("Boost is off. Choose a level to make quiet recordings louder.").assertIsDisplayed()
    }

    @Test
    fun listeningModePageSelectsAndReturns() {
        show(DenoiseState(isEnabled = true, status = AudioProcessingStatus.Active, isProcessorAttached = true))
        compose.onNodeWithContentDescription("Listening mode").performClick()
        compose.onNodeWithText("Recommended").assertIsDisplayed()
        compose.onNodeWithText("Balanced").performClick()
        assertThat(state.mode).isEqualTo(NoiseReductionMode.RNNOISE)
        compose.onNodeWithText("Enable DeNoise").assertIsDisplayed()
        // Quiet speech presets apply only to Best Quality.
        compose.onNodeWithText("Fine-tune the voice").assertDoesNotExist()
    }

    @Test
    fun quietSpeechPageSelectsAndReturns() {
        show(DenoiseState(isEnabled = true, status = AudioProcessingStatus.Active, isProcessorAttached = true))
        compose.onNodeWithText("Fine-tune the voice").performClick()
        compose.onNodeWithText("Extra Lift").performClick()
        assertThat(state.voiceFocus).isEqualTo(VoiceFocusPreset.STRONG)
        compose.onAllNodesWithText("Extra Lift").fetchSemanticsNodes().let { assertThat(it).hasSize(1) }
    }

    @Test
    fun subPageBackReturnsToTheMainPage() {
        show()
        compose.onNodeWithContentDescription("Listening mode").performClick()
        compose.onNodeWithContentDescription("Back").performClick()
        compose.onNodeWithText("Enable DeNoise").assertIsDisplayed()
        assertThat(backs).isEqualTo(0)
        compose.onNodeWithContentDescription("Back").performClick()
        assertThat(backs).isEqualTo(1)
    }
}
