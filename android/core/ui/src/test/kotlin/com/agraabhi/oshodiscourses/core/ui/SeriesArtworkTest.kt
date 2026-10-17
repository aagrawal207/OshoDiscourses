package com.agraabhi.oshodiscourses.core.ui

import androidx.compose.ui.graphics.Color
import com.agraabhi.oshodiscourses.core.ui.components.SeriesArtwork
import com.google.common.truth.Truth.assertThat
import org.junit.Test

class SeriesArtworkTest {
    @Test
    fun hashMatchesIosFnv1a() {
        // Reference computed with the Swift algorithm (FNV-1a 64 over UTF-8).
        assertThat(SeriesArtwork.stableHash("A Bird on the Wing")).isEqualTo(4430431626933109918uL)
    }

    @Test
    fun gradientUsesHashedHues() {
        val colors = SeriesArtwork.gradientColors("A Bird on the Wing")
        assertThat(colors).containsExactly(Color.hsv(238f, 0.6f, 0.5f), Color.hsv(318f, 0.7f, 0.3f)).inOrder()
    }

    @Test
    fun initialsAreFirstTwoCharactersUppercased() {
        assertThat(SeriesArtwork.initials("ah This")).isEqualTo("AH")
        assertThat(SeriesArtwork.initials("A Sudden Clash of Thunder")).isEqualTo("A ")
        assertThat(SeriesArtwork.initials("e\u0301a")).isEqualTo("E\u0301A")
        assertThat(SeriesArtwork.initials("Z")).isEqualTo("Z")
    }
}
