package com.agraabhi.oshodiscourses.feature.downloads

import com.agraabhi.oshodiscourses.core.domain.bookmarks.BookmarkCategory
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadState
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ViewModelTest {
    @Before
    fun setUp() = Dispatchers.setMain(UnconfinedTestDispatcher())

    @After
    fun tearDown() = Dispatchers.resetMain()

    private fun downloadsVM(services: com.agraabhi.oshodiscourses.core.testing.FakeAppServices) =
        DownloadsViewModel(services.catalog, services.downloads, services.player, services.bookmarks, services.listeningStats)

    @Test
    fun groupsAreSortedByNameWithSizesAndInProgressSeparate() {
        val vm = downloadsVM(Fixtures.populated())
        val state = vm.state.value
        assertThat(state.groups.map { it.series.name }).containsExactly("A Bird on the Wing", "Ashtavakra Maha Geeta").inOrder()
        assertThat(state.groups[0].subtitle).isEqualTo("2 episodes · 73 MB")
        assertThat(state.groups[0].items.map { it.discourse.number }).containsExactly(1, 2).inOrder()
        assertThat(state.inProgress.map { it.discourse.id }).containsExactly(Fixtures.geeta[1].id)
        assertThat(state.inProgress[0].progress).isEqualTo(0.42)
        assertThat(state.previouslyDownloaded.map { it.discourse.id }).containsExactly(Fixtures.bird[2].id)
        assertThat(state.totalBytes).isEqualTo(3 * 36_500_000L)
        assertThat(state.statsSubtitle).isEqualTo("18h 55m listened")
        assertThat(state.bookmarkCount).isEqualTo(5)
    }

    @Test
    fun searchMatchesSeriesOrDiscourseTitleAndHidesOtherSections() {
        val vm = downloadsVM(Fixtures.populated())
        vm.setQuery("#2")
        val state = vm.state.value
        assertThat(state.groups.single().items.single().discourse.id).isEqualTo(Fixtures.bird[1].id)
        assertThat(state.showInProgress).isFalse()
        assertThat(state.showPreviouslyDownloaded).isFalse()
        assertThat(state.showUsage).isFalse()
        vm.setQuery("BIRD")
        assertThat(vm.state.value.groups.single().items).hasSize(2)
    }

    @Test
    fun editingSelectsAndDeletesOnlyTheSelection() {
        val services = Fixtures.populated()
        val vm = downloadsVM(services)
        vm.startEditing()
        vm.toggleSelection(Fixtures.bird[0].id)
        vm.toggleSelection(Fixtures.geeta[0].id)
        vm.toggleSelection(Fixtures.geeta[0].id)
        assertThat(vm.state.value.selection).containsExactly(Fixtures.bird[0].id)
        vm.deleteSelection()
        assertThat(services.downloads.downloadedIDs.value).containsExactly(Fixtures.bird[1].id, Fixtures.geeta[0].id)
        assertThat(vm.state.value.isEditing).isFalse()
        assertThat(vm.state.value.selection).isEmpty()
    }

    @Test
    fun previouslyDownloadedSkipsActiveTransfersAndCanBeForgotten() {
        val services = Fixtures.populated()
        services.downloads.setState(Fixtures.bird[2].id, DownloadState.Queued)
        val vm = downloadsVM(services)
        assertThat(vm.state.value.previouslyDownloaded).isEmpty()
        services.downloads.setState(Fixtures.bird[2].id, DownloadState.NotDownloaded)
        assertThat(vm.state.value.previouslyDownloaded).hasSize(1)
        vm.forget(Fixtures.bird[2].id)
        assertThat(vm.state.value.previouslyDownloaded).isEmpty()
    }

    @Test
    fun playOrPauseTogglesTheCurrentTrackAndStartsOthers() {
        val services = Fixtures.populated(playing = true)
        val vm = downloadsVM(services)
        vm.playOrPause(Fixtures.bird[0].id)
        assertThat(services.player.state.value.isPlaying).isFalse()
        vm.playOrPause(Fixtures.geeta[0].id)
        assertThat(services.player.state.value.currentTrackId).isEqualTo(Fixtures.geeta[0].id)
        assertThat(services.player.state.value.queue.map { it.id }).containsExactly(Fixtures.geeta[0].id)
    }

    @Test
    fun bookmarksGroupBySeriesNewestFirstAndFilterTogglesBackToAll() {
        val services = Fixtures.populated()
        val vm = BookmarksViewModel(services.bookmarks, services.downloads, services.player, services.catalog)
        val groups = vm.state.value.groups
        assertThat(groups.map { it.seriesName }).containsExactly("A Bird on the Wing", "Ashtavakra Maha Geeta").inOrder()
        assertThat(groups[1].rows.map { it.bookmark.id }).containsExactly("b1", "b2", "b3").inOrder()
        assertThat(groups[0].rows.first { it.bookmark.id == "b4" }.availability).isEqualTo(BookmarkAvailability.DOWNLOADED)
        assertThat(groups[0].rows.first { it.bookmark.id == "b5" }.availability).isEqualTo(BookmarkAvailability.NOT_DOWNLOADED)
        assertThat(groups[1].rows.first { it.bookmark.id == "b2" }.availability).isEqualTo(BookmarkAvailability.DOWNLOADING)
        assertThat(groups[0].rows.first { it.bookmark.id == "b4" }.isPlaying).isTrue()

        vm.selectFilter(BookmarkCategory.PROFOUND)
        assertThat(vm.state.value.groups.single().rows.single().bookmark.id).isEqualTo("b3")
        vm.selectFilter(BookmarkCategory.PROFOUND)
        assertThat(vm.state.value.filter).isNull()
        vm.selectFilter(BookmarkCategory.MEDITATION)
        assertThat(vm.state.value.groups).isEmpty()
        assertThat(vm.state.value.hasBookmarks).isTrue()
    }

    @Test
    fun bookmarkPlayAndDownloadGoThroughTheContracts() {
        val services = Fixtures.populated(playing = false)
        val vm = BookmarksViewModel(services.bookmarks, services.downloads, services.player, services.catalog)
        vm.play("b1")
        assertThat(services.player.state.value.currentTrackId).isEqualTo(Fixtures.geeta[0].id)
        vm.download(Fixtures.bird[2].id)
        assertThat(services.downloads.downloadedIDs.value).contains(Fixtures.bird[2].id)
        vm.delete("b1")
        assertThat(services.bookmarks.bookmarks.value.map { it.id }).doesNotContain("b1")
    }

    @Test
    fun statsCountCompletedSeriesAndListHistoryNewestFirst() {
        val services = Fixtures.populated()
        val vm = ListeningStatsViewModel(services.listeningStats, services.playbackState, services.catalog) { Fixtures.today }
        val state = vm.state.value
        assertThat(state.allTime).isEqualTo("18h 55m")
        assertThat(state.streak).isEqualTo("4d")
        assertThat(state.discoursesDone).isEqualTo(3)
        assertThat(state.seriesDone).isEqualTo(1)
        assertThat(state.today).isEqualTo("17 min")
        assertThat(state.historyCount).isEqualTo(3)
        assertThat(state.days.first().label).isEqualTo("Today")
        assertThat(state.days[1].label).isEqualTo("Yesterday")
        assertThat(state.played.map { it.title }.first()).isEqualTo("A Bird on the Wing - #1")
        assertThat(state.played.first { it.id == Fixtures.bird[1].id }.positionText).isNull()
    }
}
