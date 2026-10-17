package com.agraabhi.oshodiscourses.core.domain

import com.agraabhi.oshodiscourses.core.domain.bookmarks.Bookmark
import com.agraabhi.oshodiscourses.core.domain.bookmarks.BookmarkCategory
import com.agraabhi.oshodiscourses.core.domain.player.AudioMixFailure
import com.agraabhi.oshodiscourses.core.domain.player.AudioProcessingStatus
import com.agraabhi.oshodiscourses.core.domain.settings.UserSettings
import com.agraabhi.oshodiscourses.core.domain.sleep.SleepTimerMode
import com.agraabhi.oshodiscourses.core.domain.sleep.SleepTimerState
import com.agraabhi.oshodiscourses.core.domain.sync.CloudSnapshot
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptAnchor
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptSyncedState
import com.agraabhi.oshodiscourses.core.model.AccentTheme
import com.agraabhi.oshodiscourses.core.model.Appearance
import com.google.common.truth.Truth.assertThat
import kotlinx.serialization.json.Json
import org.junit.Test

class ContractValueTest {
    @Test
    fun settingsDefaultsMatchIos() {
        val s = UserSettings()
        assertThat(s.appearance).isEqualTo(Appearance.LIGHT)
        assertThat(s.accentTheme).isEqualTo(AccentTheme.PURPLE)
        assertThat(s.smartDownload).isTrue()
        assertThat(s.autoPlayNext).isTrue()
        assertThat(s.allowCellularDownloads).isFalse()
        assertThat(s.volumeBoost).isEqualTo(2.0)
        assertThat(s.transcriptFontSize).isEqualTo(19.0)
        assertThat(s.effectiveAccentTheme).isEqualTo(AccentTheme.PURPLE)
        assertThat(s.copy(dailyAccentShuffle = true, shuffledThemeToday = AccentTheme.MINT).effectiveAccentTheme)
            .isEqualTo(AccentTheme.MINT)
    }

    @Test
    fun sleepTimerLabels() {
        assertThat(SleepTimerState().statusLabel).isEqualTo("Sleep")
        assertThat(SleepTimerState(SleepTimerMode.COUNTDOWN, 125.9).statusLabel).isEqualTo("2:05")
        assertThat(SleepTimerState(SleepTimerMode.END_OF_DISCOURSE).statusLabel).isEqualTo("End")
    }

    @Test
    fun bookmarkFormatting() {
        val b = Bookmark(id = "1", discourseID = "d", seriesName = "S", title = "T", timestamp = 3_725.0, createdAt = 0)
        assertThat(b.formattedTimestamp).isEqualTo("1:02:05")
        assertThat(b.copy(timestamp = 65.0).formattedTimestamp).isEqualTo("1:05")
        assertThat(b.copy(category = BookmarkCategory.CUSTOM, customCategory = "Zen").displayCategory).isEqualTo("Zen")
        assertThat(b.copy(category = BookmarkCategory.CUSTOM).displayCategory).isEqualTo("Custom")
    }

    @Test
    fun processingStatusCopy() {
        assertThat(AudioProcessingStatus.Off.label).isEqualTo("Original sound")
        assertThat(AudioProcessingStatus.SetupFailed(AudioMixFailure.PLAYBACK).label).isEqualTo("Playback unavailable")
        assertThat(AudioProcessingStatus.SetupFailed(AudioMixFailure.TAP_CREATION).outcome).isEqualTo("setup_tapCreation")
        assertThat(AudioProcessingStatus.Bypassing.isIssue).isTrue()
    }

    @Test
    fun snapshotRoundTripsAndToleratesMissingOptionalFields() {
        val snapshot = CloudSnapshot(
            positions = mapOf("d-1" to 12.5),
            bookmarks = listOf(Bookmark("b", "d-1", "S", "T", 3.0, category = BookmarkCategory.PROFOUND, createdAt = 9)),
            transcripts = mapOf("d-1" to TranscriptSyncedState(anchors = listOf(TranscriptAnchor(2, 30.0, 5)))),
        )
        val json = Json { ignoreUnknownKeys = true }
        assertThat(json.decodeFromString<CloudSnapshot>(json.encodeToString(snapshot))).isEqualTo(snapshot)
        assertThat(json.decodeFromString<CloudSnapshot>("{\"completed\":[\"a\"]}").played).isNull()
        assertThat(json.encodeToString(BookmarkCategory.RELISTEN)).isEqualTo("\"Re-listen\"")
    }
}
