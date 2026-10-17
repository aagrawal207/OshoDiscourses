package com.agraabhi.oshodiscourses.core.testing

import app.cash.turbine.test
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadState
import com.agraabhi.oshodiscourses.core.domain.player.PlayResult
import com.agraabhi.oshodiscourses.core.model.Language
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.test.runTest
import org.junit.Test

class FakeAppServicesTest {
    @Test
    fun sampleCatalogHasOneHindiSeries() {
        val catalog = FakeCatalogRepository()
        assertThat(catalog.allSeries).hasSize(2)
        assertThat(catalog.hindiSeries.single().language).isEqualTo(Language.HINDI)
        assertThat(catalog.entry(SampleCatalog.firstDiscourse.id)?.series).isEqualTo(SampleCatalog.birdOnTheWing)
        assertThat(catalog.discourseSubtitle(1, "A Bird on the Wing")).isEqualTo("Discourse 1 · Mumbai, 1974")
    }

    @Test
    fun playbackIsDownloadOnly() = runTest {
        val services = FakeAppServices()
        val id = SampleCatalog.firstDiscourse.id
        assertThat(services.player.play(id)).isEqualTo(PlayResult.Failure.NOT_DOWNLOADED)

        services.downloads.state(id).let { assertThat(it).isEqualTo(DownloadState.NotDownloaded) }
        services.downloads.enqueue(id)
        services.player.state.test {
            assertThat(awaitItem().hasTrack).isFalse()
            assertThat(services.player.play(id)).isEqualTo(PlayResult.Started)
            val playing = awaitItem()
            assertThat(playing.currentTrackId).isEqualTo(id)
            assertThat(playing.isPlaying).isTrue()
            assertThat(playing.queue).hasSize(1)
        }
    }

    @Test
    fun bookmarkPlaybackSeeksToTimestamp() = runTest {
        val services = FakeAppServices(downloads = FakeDownloadManager(setOf(SampleCatalog.firstDiscourse.id)))
        val bookmark = services.bookmarks.add(SampleCatalog.firstDiscourse.id, "A Bird on the Wing", "A Bird on the Wing - #1", 120.0)
        assertThat(services.player.playBookmark(bookmark.id)).isEqualTo(PlayResult.Started)
        assertThat(services.player.state.value.currentTime).isEqualTo(120.0)
    }
}
