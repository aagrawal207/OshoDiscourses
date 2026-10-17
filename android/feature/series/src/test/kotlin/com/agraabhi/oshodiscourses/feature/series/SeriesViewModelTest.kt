package com.agraabhi.oshodiscourses.feature.series

import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadState
import com.agraabhi.oshodiscourses.core.domain.downloads.WaitingReason
import com.agraabhi.oshodiscourses.core.model.Language
import com.agraabhi.oshodiscourses.core.testing.FakeAppServices
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SeriesViewModelTest {
    private val dispatcher = StandardTestDispatcher()
    private val series = SeriesFixtures.bird

    @Before
    fun setUp() = Dispatchers.setMain(dispatcher)

    @After
    fun tearDown() = Dispatchers.resetMain()

    private fun viewModel(services: FakeAppServices) = SeriesViewModel(
        seriesID = series.id,
        catalog = services.catalog,
        downloads = services.downloads,
        playbackState = services.playbackState,
        player = services.player,
        transcripts = services.transcripts,
    )

    private fun id(n: Int) = SeriesFixtures.id(series, n)

    @Test
    fun initialStateIsBuiltSynchronously() {
        val vm = viewModel(SeriesFixtures.allStates())
        val rows = vm.state.value.rows
        assertThat(rows).hasSize(9)
        assertThat(rows[0].isCurrentlyPlaying).isTrue()
        assertThat(rows[1].isCompleted).isTrue()
        assertThat(rows[2].download).isInstanceOf(DownloadState.Downloading::class.java)
        assertThat(rows[4].failureMessage).isEqualTo("The download stopped responding. Check your connection and try again.")
        assertThat(rows[5].waitingLabel).isEqualTo("Waiting for Wi-Fi")
        assertThat(rows[6].hasTranscript).isFalse()
        assertThat(vm.state.value.completedCount).isEqualTo(2)
        assertThat(vm.state.value.remainingCount).isEqualTo(7)
        assertThat(vm.state.value.waitingReason).isEqualTo(WaitingReason.WIFI)
    }

    @Test
    fun waitingNoticeNeedsAnOwnTransferThatIsNotJustQueued() = runTest(dispatcher) {
        val services = SeriesFixtures.fresh(series)
        services.downloads.waitingReason.value = WaitingReason.CONNECTION
        services.downloads.setState(id(1), DownloadState.Queued)
        val vm = viewModel(services)
        assertThat(vm.state.value.waitingReason).isNull()

        services.downloads.setState(id(2), DownloadState.WaitingForConnection)
        val updated = vm.state.first { it.waitingReason != null }
        assertThat(updated.waitingReason).isEqualTo(WaitingReason.CONNECTION)
    }

    @Test
    fun downloadHintLastsTwoSeconds() = runTest(dispatcher) {
        val services = SeriesFixtures.fresh(series)
        services.downloads.completeInstantly = false
        val vm = viewModel(services)
        backgroundScope.launch { vm.state.collect {} }
        vm.onRowTap(id(3))
        runCurrent()
        assertThat(vm.state.value.rows[2].showsDownloadHint).isTrue()
        assertThat(services.downloads.state(id(3))).isEqualTo(DownloadState.Queued)
        advanceTimeBy(SeriesViewModel.DOWNLOAD_HINT_MILLIS + 1)
        runCurrent()
        assertThat(vm.state.value.rows[2].showsDownloadHint).isFalse()
    }

    @Test
    fun actionTapCancelsRetriesAndToggles() = runTest(dispatcher) {
        val services = SeriesFixtures.allStates()
        val vm = viewModel(services)
        vm.onActionTap(id(3))
        vm.onActionTap(id(5))
        vm.onActionTap(id(1))
        advanceUntilIdle()
        assertThat(services.downloads.state(id(3))).isEqualTo(DownloadState.NotDownloaded)
        assertThat(services.downloads.state(id(5))).isEqualTo(DownloadState.Downloaded)
        assertThat(services.player.state.value.isPlaying).isFalse()
    }

    @Test
    fun downloadAllSkipsWhatIsOnDisk() = runTest(dispatcher) {
        val services = SeriesFixtures.allStates()
        services.downloads.completeInstantly = false
        val vm = viewModel(services)
        vm.downloadAll()
        advanceUntilIdle()
        assertThat(services.downloads.state(id(1))).isEqualTo(DownloadState.Downloaded)
        assertThat(services.downloads.state(id(7))).isEqualTo(DownloadState.Queued)
        assertThat(services.downloads.state(id(9))).isEqualTo(DownloadState.Queued)
        assertThat(services.downloads.state(id(3))).isInstanceOf(DownloadState.Downloading::class.java)
    }

    @Test
    fun sizeEstimatesMatchIOS() {
        assertThat(DownloadEstimate.perDiscourseLabel(Language.HINDI)).isEqualTo("~20 MB")
        assertThat(DownloadEstimate.perDiscourseLabel(Language.ENGLISH)).isEqualTo("~30 MB")
        assertThat(DownloadEstimate.totalLabel(3, Language.ENGLISH)).isEqualTo("~90 MB")
        assertThat(DownloadEstimate.totalLabel(33, Language.ENGLISH)).isEqualTo("~990 MB")
        assertThat(DownloadEstimate.totalLabel(50, Language.HINDI)).isEqualTo("~1.0 GB")
        assertThat(DownloadEstimate.totalLabel(41, Language.ENGLISH)).isEqualTo("~1.2 GB")
        assertThat(DownloadEstimate.totalLabel(0, Language.HINDI)).isEqualTo("~0 MB")
    }

    @Test
    fun accessibilityLabelListsCompletionAndTranscript() {
        val rows = viewModel(SeriesFixtures.allStates()).state.value.rows
        assertThat(rows[1].accessibilityLabel).isEqualTo("Discourse 2, completed, transcript available")
        assertThat(rows[7].accessibilityLabel).isEqualTo("Discourse 8")
    }
}
