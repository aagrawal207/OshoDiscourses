package com.agraabhi.oshodiscourses.feature.player

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.click
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.agraabhi.oshodiscourses.core.testing.FakeAppServices
import com.google.common.truth.Truth.assertThat
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [36], qualifiers = "w393dp-h852dp-xxhdpi")
class MiniPlayerInteractionTest {
    @get:Rule
    val compose = createComposeRule()

    private var opened = 0
    private var height: Dp = 0.dp

    private fun show(services: FakeAppServices) {
        compose.setContent {
            TestHost(services) { MiniPlayer(onOpenPlayer = { opened++ }, onHeightChanged = { height = it }) }
        }
    }

    private val bar = "Discourse 1, A Bird on the Wing"

    @Test
    fun tapOpensThePlayer() {
        show(playerServices())
        compose.onNodeWithContentDescription(bar).performClick()
        assertThat(opened).isEqualTo(1)
    }

    @Test
    fun playPauseButtonTogglesWithoutOpening() {
        val services = playerServices()
        show(services)
        compose.onNodeWithContentDescription(bar)
            .assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Playing"))
            .performTouchInput { click(Offset(right - 40f * density, centerY)) }
        assertThat(services.player.state.value.isPlaying).isFalse()
        assertThat(services.reviewPrompter.requests).isEqualTo(1)
        assertThat(opened).isEqualTo(0)
        compose.onNodeWithContentDescription(bar).assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Paused"))
    }

    /** iOS measures about 62.5; the shell turns this into LocalMiniPlayerClearance. */
    @Test
    fun reportsItsMeasuredHeight() {
        show(playerServices())
        compose.waitForIdle()
        assertThat(height.value).isWithin(1.5f).of(62.5f)
    }
}
