package com.agraabhi.oshodiscourses

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.agraabhi.oshodiscourses.core.domain.bookmarks.Bookmark
import com.agraabhi.oshodiscourses.core.domain.sync.CloudSnapshot
import com.agraabhi.oshodiscourses.core.testing.FakeDownloadManager
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.test.runTest
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [36])
class AppWiringTest {
    @Test
    fun driveFileUsesTheIosSnapshotShapeAndRejectsGarbage() {
        val snapshot = CloudSnapshot(
            positions = mapOf("english-A_Bird_on_the_Wing__-1" to 375.7),
            recentlyPlayed = listOf("english-A_Bird_on_the_Wing__-1"),
            bookmarks = listOf(Bookmark("b-1", "english-A_Bird_on_the_Wing__-1", "A Bird on the Wing", "#1", 42.0, createdAt = 1_792_238_400_000L)),
            dailyStats = mapOf("2026-10-17" to 600.0),
        )
        val text = IosSnapshotCodec.encode(snapshot)
        // Swift `JSONEncoder` dates are seconds since 2001, not epoch milliseconds.
        assertThat(text).doesNotContain("1792238400000")
        assertThat(IosSnapshotCodec.decode(text)).isEqualTo(snapshot)
        assertThat(IosSnapshotCodec.decode("<html>not a snapshot</html>")).isNull()
    }

    @Test
    fun screenDownloadsAskForNotificationsOnlyOnce() = runTest {
        val app: Application = ApplicationProvider.getApplicationContext()
        val engine = FakeDownloadManager()
        var asked = 0
        val prompt = NotificationPermissionPrompt(app) { asked++; null }
        val downloads = PromptingDownloadManager(engine, prompt)

        downloads.enqueue("english-A_Bird_on_the_Wing__-1")
        downloads.enqueueAll(listOf("english-A_Bird_on_the_Wing__-2"))

        assertThat(engine.inProgressIDs() + engine.downloadedIDs.value).containsAtLeast("english-A_Bird_on_the_Wing__-1", "english-A_Bird_on_the_Wing__-2")
        // No foreground activity means no dialog, and the prompt is not spent.
        assertThat(asked).isEqualTo(2)
    }
}
