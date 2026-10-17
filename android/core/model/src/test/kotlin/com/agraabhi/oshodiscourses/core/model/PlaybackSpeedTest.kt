package com.agraabhi.oshodiscourses.core.model

import com.google.common.truth.Truth.assertThat
import org.junit.Test

class PlaybackSpeedTest {
    @Test
    fun normalizedSnapsToTwentiethsAndClamps() {
        assertThat(PlaybackSpeed.normalized(0.86f)).isEqualTo(0.85f)
        assertThat(PlaybackSpeed.normalized(3f)).isEqualTo(2f)
        assertThat(PlaybackSpeed.normalized(0.1f)).isEqualTo(0.5f)
        assertThat(PlaybackSpeed.normalized(Float.NaN)).isEqualTo(1f)
    }

    @Test
    fun steppedMovesOneGridStep() {
        assertThat(PlaybackSpeed.stepped(1f, 1)).isEqualTo(1.05f)
        assertThat(PlaybackSpeed.stepped(2f, 1)).isEqualTo(2f)
        assertThat(PlaybackSpeed.stepped(0.5f, -1)).isEqualTo(0.5f)
    }

    @Test
    fun labelsDropTrailingZeros() {
        assertThat(PlaybackSpeed.label(1f)).isEqualTo("1×")
        assertThat(PlaybackSpeed.label(1.25f)).isEqualTo("1.25×")
        assertThat(PlaybackSpeed.label(0.85f)).isEqualTo("0.85×")
        assertThat(PlaybackSpeed.label(1.5f)).isEqualTo("1.5×")
        assertThat(PlaybackSpeed.accessibilityLabel(1.1f)).isEqualTo("1.1 times")
    }

    @Test
    fun accentShuffleCyclesThroughPaletteAndHandlesNegativeDays() {
        assertThat(AccentTheme.shuffled(0)).isEqualTo(AccentTheme.BLUE)
        assertThat(AccentTheme.shuffled(9)).isEqualTo(AccentTheme.TEAL)
        assertThat(AccentTheme.shuffled(-1)).isEqualTo(AccentTheme.MINT)
    }
}
