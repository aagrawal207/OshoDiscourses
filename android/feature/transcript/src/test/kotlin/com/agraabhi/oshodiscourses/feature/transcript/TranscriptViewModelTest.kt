package com.agraabhi.oshodiscourses.feature.transcript

import com.agraabhi.oshodiscourses.core.domain.player.PlayerState
import com.agraabhi.oshodiscourses.core.domain.settings.UserSettings
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptDiscourseState
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptException
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptReadPosition
import com.agraabhi.oshodiscourses.core.testing.FakeCatalogRepository
import com.agraabhi.oshodiscourses.core.testing.FakePlayerController
import com.agraabhi.oshodiscourses.core.testing.FakeSettingsRepository
import com.agraabhi.oshodiscourses.core.testing.FakeTranscriptRepository
import com.agraabhi.oshodiscourses.core.testing.FakeTranscriptStateRepository
import com.agraabhi.oshodiscourses.feature.transcript.text.RowID
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class TranscriptViewModelTest {
    private val dispatcher = UnconfinedTestDispatcher()
    private val transcript = TranscriptFixtures.englishTranscript
    private val id = transcript.discourseID
    private val catalog = FakeCatalogRepository()
    private val player = FakePlayerController(catalog)
    private val settings = FakeSettingsRepository()
    private val states = FakeTranscriptStateRepository()

    @Before
    fun setUp() = Dispatchers.setMain(dispatcher)

    @After
    fun tearDown() = Dispatchers.resetMain()

    private fun viewModel(
        repository: com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptRepository = ModelTimingRepository(TranscriptFixtures.repository()),
        discourseID: String = id,
    ) = TranscriptViewModel(discourseID, catalog, repository, states, player, settings).also { it.start() }

    private fun playing(time: Double, duration: Double = 1_000.0, isPlaying: Boolean = true) = player.state.update {
        PlayerState(currentTrackId = id, currentTime = time, duration = duration, isPlaying = isPlaying)
    }

    @Test
    fun loadsRowsAndTitle() = runTest(dispatcher) {
        val vm = viewModel()
        val s = vm.state.value
        assertThat(s.isLoaded).isTrue()
        assertThat(s.rows.size).isGreaterThan(transcript.paragraphs.size)
        assertThat(s.seriesName).isEqualTo("A Bird on the Wing")
        assertThat(s.discourseNumber).isEqualTo(1)
        assertThat(s.isFollowing).isTrue()
        assertThat(vm.scrollCommands.first()).isEqualTo(ScrollCommand(0, ScrollMotion.JUMP))
    }

    @Test
    fun highlightFollowsPlaybackAndScrolls() = runTest(dispatcher) {
        playing(0.0)
        val vm = viewModel()
        assertThat(vm.state.value.currentRow).isEqualTo(RowID(0, 0))
        vm.scrollCommands.first()
        playing(990.0)
        val s = vm.state.value
        assertThat(s.currentRow?.paragraph).isEqualTo(transcript.paragraphs.lastIndex)
        assertThat(vm.scrollCommands.first()).isEqualTo(ScrollCommand(s.currentOrdinal!!, ScrollMotion.FOLLOW))
        // Estimated timing never marks a single sentence.
        assertThat(s.currentSentence).isNull()
        assertThat(s.timingNote).startsWith("Estimated from text length.")
    }

    @Test
    fun alignedTimingMarksTheSentence() = runTest(dispatcher) {
        settings.setTranscriptSentenceLayout(false)
        playing(500.0)
        val vm = viewModel(ModelTimingRepository(TranscriptFixtures.repository(), aligned = true))
        assertThat(vm.state.value.alignmentInUse).isTrue()
        assertThat(vm.state.value.currentSentence).isNotNull()
        val count = transcript.paragraphs.size
        assertThat(vm.state.value.timingNote).isEqualTo("Synced from speech: $count of $count paragraphs")
    }

    @Test
    fun notPublishedAndFailures() = runTest(dispatcher) {
        assertThat(viewModel(discourseID = "english-unknown-1").state.value.content).isEqualTo(TranscriptContent.NotPublished)
        val blank = viewModel(TranscriptFixtures.repository(failure = TranscriptException.Blank())).state.value.content
        assertThat(blank).isEqualTo(TranscriptContent.Failed("oshoworld.com has no text for this discourse yet.", canRetry = false))
        val offline = viewModel(TranscriptFixtures.repository(failure = TranscriptException.Network("The Internet connection appears to be offline."))).state.value.content
        assertThat((offline as TranscriptContent.Failed).canRetry).isTrue()
    }

    @Test
    fun restoresTheReadPositionAndSavesManualScrolls() = runTest(dispatcher) {
        states.states.value = mapOf(id to TranscriptDiscourseState(readPosition = TranscriptReadPosition(4, 1), paragraphCount = transcript.paragraphs.size))
        playing(0.0)
        val vm = viewModel()
        val s = vm.state.value
        assertThat(s.isFollowing).isFalse()
        val first = s.rows.first { it.paragraph == 4 }
        assertThat(vm.scrollCommands.first()).isEqualTo(ScrollCommand(first.ordinal, ScrollMotion.JUMP))
        assertThat(s.showsNowPlaying).isTrue()
        assertThat(s.copy(scrolledRow = first.id).nowPlayingIsBelow).isFalse()

        vm.onScrolledRowChanged(s.rows.first { it.paragraph == 6 }.id)
        assertThat(states.states.value[id]?.readPosition?.paragraph).isEqualTo(6)

        vm.resumeFollowing()
        assertThat(vm.state.value.isFollowing).isTrue()
        assertThat(states.states.value[id]?.readPosition?.isFollowing).isTrue()
        vm.onScrolledRowChanged(s.rows.first { it.paragraph == 2 }.id)
        assertThat(states.states.value[id]?.readPosition?.isFollowing).isTrue()
    }

    @Test
    fun userScrollStopsFollowing() = runTest(dispatcher) {
        val vm = viewModel()
        vm.onUserScroll()
        assertThat(vm.state.value.isFollowing).isFalse()
    }

    @Test
    fun audioIsHereAnchorsTheRowAndPlayFromHereSeeks() = runTest(dispatcher) {
        playing(100.0)
        val vm = viewModel()
        val row = vm.state.value.rows.first { it.paragraph == 2 && it.id.index == 1 }
        vm.onRowTap(row)
        assertThat(vm.state.value.tappedRow).isEqualTo(row.id)
        vm.anchorHere(row)
        val anchor = states.states.value[id]!!.anchors.single()
        assertThat(anchor.paragraph).isEqualTo(2)
        assertThat(anchor.time).isEqualTo(100.0)
        assertThat(anchor.fraction).isEqualTo(row.midpoint)
        assertThat(vm.state.value.toast).isEqualTo("Synced to this sentence")
        assertThat(vm.state.value.tappedRow).isNull()
        assertThat(vm.state.value.anchorCount).isEqualTo(1)
        assertThat(vm.state.value.clearAnchorsLabel).isEqualTo("Clear 1 sync anchor")
        // The anchor bends the map: that row is now the one being spoken.
        assertThat(vm.state.value.currentRow).isEqualTo(row.id)

        player.state.update { it.copy(isPlaying = false) }
        val later = vm.state.value.rows.first { it.paragraph == 8 }
        vm.playFromHere(later)
        assertThat(player.state.value.currentTime).isGreaterThan(100.0)
        assertThat(player.state.value.isPlaying).isTrue()
        assertThat(player.state.value.previousPosition).isEqualTo(100.0)

        vm.clearAnchors()
        assertThat(vm.state.value.anchorCount).isEqualTo(0)
    }

    @Test
    fun copyAndPassageSelection() = runTest(dispatcher) {
        val vm = viewModel()
        val rows = vm.state.value.rows
        vm.startSelecting(rows[1])
        assertThat(vm.state.value.isSelecting).isTrue()
        assertThat(vm.state.value.selectionCountLabel).isEqualTo("1 selected")
        assertThat(vm.canSelectUpToHere(rows[4])).isTrue()
        vm.selectUpToHere(rows[4])
        assertThat(vm.state.value.selection).hasSize(4)
        vm.onRowTap(rows[2])
        assertThat(vm.state.value.selection).hasSize(3)
        vm.copySelection()
        val effect = vm.effects.first() as TranscriptEffect.Copy
        assertThat(effect.text).startsWith(rows[1].text)
        assertThat(vm.state.value.toast).isEqualTo("Copied 3 passages")
        assertThat(vm.state.value.isSelecting).isFalse()

        vm.share(listOf(rows[0]))
        assertThat((vm.effects.first() as TranscriptEffect.Share).text).endsWith("— Osho, A Bird on the Wing #1")
        vm.openTextSelection(listOf(rows[0]))
        assertThat(vm.state.value.textSelection?.text).isEqualTo(rows[0].text)
        vm.closeTextSelection()
        assertThat(vm.state.value.textSelection).isNull()
    }

    @Test
    fun searchFindsRowsAndCycles() = runTest(dispatcher) {
        val vm = viewModel()
        vm.toggleSearch()
        vm.setSearchQuery("RIVER")
        val s = vm.state.value
        assertThat(s.searchMatches.size).isAtLeast(2)
        assertThat(s.searchCounter).isEqualTo("1/${s.searchMatches.size}")
        assertThat(s.isFollowing).isFalse()
        vm.jumpToMatch(-1)
        assertThat(vm.state.value.searchCursor).isEqualTo(s.searchMatches.lastIndex)
        vm.setSearchQuery("zz")
        assertThat(vm.state.value.searchCounter).isEqualTo("0/0")
        vm.setSearchQuery("z")
        assertThat(vm.state.value.searchCounter).isNull()
        vm.cancelSearch()
        assertThat(vm.state.value.isSearching).isFalse()
        assertThat(vm.state.value.searchQuery).isEmpty()
    }

    @Test
    fun layoutAndFontSizeOptions() = runTest(dispatcher) {
        val vm = viewModel()
        val sentenceRows = vm.state.value.rows.size
        vm.setSentenceLayout(false)
        assertThat(vm.state.value.rows.size).isEqualTo(transcript.paragraphs.size)
        assertThat(sentenceRows).isGreaterThan(transcript.paragraphs.size)

        vm.stepFontSize(1)
        assertThat(settings.settings.value.transcriptFontSize).isEqualTo(21.0)
        repeat(5) { vm.stepFontSize(1) }
        assertThat(vm.state.value.fontSize).isEqualTo(28.0)
        assertThat(vm.state.value.canGrowText).isFalse()
        repeat(9) { vm.stepFontSize(-1) }
        assertThat(vm.state.value.fontSize).isEqualTo(UserSettings.TRANSCRIPT_FONT_SIZES.first())
        assertThat(vm.state.value.canShrinkText).isFalse()
    }

    @Test
    fun anotherDiscourseInThePlayerDisablesPlaybackFeatures() = runTest(dispatcher) {
        player.state.update { PlayerState(currentTrackId = "other", currentTime = 10.0, duration = 100.0, isPlaying = true) }
        val vm = viewModel(ModelTimingRepository(FakeTranscriptRepository(mapOf(id to transcript))))
        val s = vm.state.value
        assertThat(s.isPlayingThis).isFalse()
        assertThat(s.currentRow).isNull()
        assertThat(s.timingNote).isNull()
        assertThat(s.showsNowPlaying).isFalse()
    }
}
