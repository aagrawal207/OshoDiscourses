package com.agraabhi.oshodiscourses.core.domain.progress

import com.google.common.truth.Truth.assertThat
import org.junit.Test

class ContinueListeningTest {
    private val progress = PlaybackProgress(
        positions = mapOf("saved" to 60.0, "relistened" to 30.0, "deleted" to 90.0, "zero" to 0.0, "unknown" to 10.0),
        recentlyPlayed = listOf("deleted", "zero", "current", "relistened", "unknown", "saved", "never"),
        completedDiscourseIDs = setOf("relistened"),
    )
    private val downloaded = setOf("saved", "relistened", "zero", "current", "unknown", "never")

    private fun ids(current: String?) = ContinueListening.discourseIDs(progress, downloaded, current) { it != "unknown" }

    @Test
    fun keepsRecentOrderAndNeedsADownloadAPositionAndACatalogEntry() {
        assertThat(ids(current = null)).containsExactly("relistened", "saved").inOrder()
    }

    @Test
    fun theLoadedTalkCountsBeforeItsFirstSave() {
        assertThat(ids(current = "current")).containsExactly("current", "relistened", "saved").inOrder()
    }

    @Test
    fun nothingRecentMeansNothingToContinue() {
        assertThat(ContinueListening.discourseIDs(PlaybackProgress(), downloaded, null) { true }).isEmpty()
    }
}
