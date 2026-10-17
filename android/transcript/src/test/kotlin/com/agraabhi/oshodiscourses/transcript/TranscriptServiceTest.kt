package com.agraabhi.oshodiscourses.transcript

import com.agraabhi.oshodiscourses.core.domain.transcript.TimingSource
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptAlignment
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptAnchor
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptAvailability
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptDiscourseState
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptException
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import kotlin.test.assertFailsWith

@OptIn(ExperimentalCoroutinesApi::class)
class TranscriptServiceTest {
    @get:Rule
    val folder = TemporaryFolder()

    private val bird = "english-A_Bird_on_the_Wing__-1"
    private val geeta = "hindi-Maha_Geeta-1"
    private val catalog = TranscriptCatalog(
        mapOf(
            bird to TranscriptCatalog.Entry("6878dc6679c7824a20c86a2e", "a-bird-on-the-wing-01", 8771),
            geeta to TranscriptCatalog.Entry("66265929d26d4da463e8850d", "ashtavakra-maha-geeta-01", 11351),
            "english-Blank-1" to TranscriptCatalog.Entry("b1", "blank-1"),
            "english-Blank-2" to TranscriptCatalog.Entry("b2", "blank-2"),
        ),
    )
    private val alignments = AlignmentCatalog(mapOf(bird to "3;3000;0,1000,1000"))
    private val text = (1..60).joinToString(" ") { "Word$it" }

    private fun TestScope.service(
        directory: File = File(folder.root, "transcripts"),
        fetch: suspend (TranscriptCatalog.Entry, Boolean) -> String,
    ): TranscriptService {
        val dispatcher = UnconfinedTestDispatcher(testScheduler)
        return TranscriptService(
            directory = directory,
            catalog = lazyOf(catalog),
            alignments = lazyOf(alignments),
            fetchHTML = fetch,
            ioDispatcher = dispatcher,
            parseDispatcher = dispatcher,
            clock = { 1_000L },
            scope = CoroutineScope(SupervisorJob() + dispatcher),
        )
    }

    @Test
    fun fetchesOnceThenServesFromDisk() = runTest {
        var calls = 0
        val directory = File(folder.root, "transcripts")
        val service = service(directory) { _, _ -> calls++; "<strong>Q</strong><br>$text" }
        assertThat(service.availability(bird)).isEqualTo(TranscriptAvailability.NOT_CACHED)

        val first = service.transcript(bird)
        assertThat(first.paragraphs).hasSize(2)
        assertThat(first.paragraphs[0].isEmphasis).isTrue()
        assertThat(first.sourceID).isEqualTo("6878dc6679c7824a20c86a2e")
        assertThat(first.fetchedAt).isEqualTo(1_000L)
        assertThat(service.availability(bird)).isEqualTo(TranscriptAvailability.CACHED)
        assertThat(service.cachedIDs.value).containsExactly(bird)
        assertThat(File(directory, "$bird.json").isFile).isTrue()
        assertThat(service.transcript(bird)).isSameInstanceAs(first)
        assertThat(calls).isEqualTo(1)

        // A fresh service over the same folder reads the file, not the network.
        val again = service(directory) { _, _ -> calls++; "" }
        assertThat(again.availability(bird)).isEqualTo(TranscriptAvailability.CACHED)
        assertThat(again.transcript(bird)).isEqualTo(first)
        assertThat(calls).isEqualTo(1)

        again.remove(bird)
        assertThat(again.availability(bird)).isEqualTo(TranscriptAvailability.NOT_CACHED)
        assertThat(File(directory, "$bird.json").exists()).isFalse()
        assertThat(directory.listFiles().orEmpty().toList()).isEmpty()
    }

    @Test
    fun blankPageIsAnErrorAndNotCached() = runTest {
        val service = service { _, _ -> "<p><br><hr></p>" }
        assertFailsWith<TranscriptException.Blank> { service.transcript(bird) }
        assertThat(service.availability(bird)).isEqualTo(TranscriptAvailability.NOT_CACHED)
        assertThat(service.loadingIDs.value).isEmpty()
    }

    @Test
    fun underFiftyWordsIsBlank() = runTest {
        val service = service { _, _ -> (1..49).joinToString(" ") }
        assertFailsWith<TranscriptException.Blank> { service.transcript(bird) }
    }

    @Test
    fun unknownDiscourseIsUnavailableWithoutNetwork() = runTest {
        var calls = 0
        val service = service { _, _ -> calls++; "" }
        assertThat(service.availability("nope-1")).isEqualTo(TranscriptAvailability.UNAVAILABLE)
        assertFailsWith<TranscriptException.NoDescription> { service.transcript("nope-1") }
        assertThat(calls).isEqualTo(0)
    }

    @Test
    fun corruptCacheFileIsForgottenAndRefetched() = runTest {
        val directory = File(folder.root, "transcripts").apply { mkdirs() }
        File(directory, "$bird.json").writeText("{ not json")
        var calls = 0
        val service = service(directory) { _, _ -> calls++; text }
        assertThat(service.availability(bird)).isEqualTo(TranscriptAvailability.CACHED)
        assertThat(service.transcript(bird).paragraphs).hasSize(1)
        assertThat(calls).isEqualTo(1)
        assertThat(service.availability(bird)).isEqualTo(TranscriptAvailability.CACHED)
    }

    @Test
    fun concurrentReadsShareOneFetchAndReportLoading() = runTest {
        val gate = CompletableDeferred<String>()
        var calls = 0
        val service = service { _, _ -> calls++; gate.await() }
        val a = async { service.transcript(bird) }
        val b = async { service.transcript(bird) }
        runCurrent()
        assertThat(service.loadingIDs.value).containsExactly(bird)
        gate.complete(text)
        assertThat(a.await()).isEqualTo(b.await())
        assertThat(calls).isEqualTo(1)
        assertThat(service.loadingIDs.value).isEmpty()
    }

    @Test
    fun fetchCompletesAndCachesEvenWhenTheReaderLeaves() = runTest {
        val gate = CompletableDeferred<String>()
        val service = service { _, _ -> gate.await() }
        val reader = async { service.transcript(bird) }
        runCurrent()
        reader.cancel()
        gate.complete(text)
        runCurrent()
        assertThat(service.availability(bird)).isEqualTo(TranscriptAvailability.CACHED)
    }

    @Test
    fun prefetchIsSilentAndSkipsWhatIsCachedOrUnknown() = runTest {
        var calls = 0
        val service = service { entry, _ ->
            calls++
            if (entry.id == "b1") throw TranscriptException.Network("offline")
            text
        }
        service.prefetch("english-Blank-1")
        assertThat(calls).isEqualTo(1)
        service.prefetch(bird, allowsCellular = false)
        service.prefetch(bird)
        service.prefetch("nope-1")
        assertThat(calls).isEqualTo(2)
        assertThat(service.cachedIDs.value).containsExactly(bird)
    }

    @Test
    fun prefetchPassesTheCellularPolicyThrough() = runTest {
        val seen = mutableListOf<Boolean>()
        val service = service { _, allowsCellular -> seen += allowsCellular; text }
        service.prefetch(bird, allowsCellular = false)
        service.backfill(listOf(geeta), allowsCellular = true)
        assertThat(seen).containsExactly(false, true).inOrder()
    }

    @Test
    fun backfillSkipsSiteErrorsButStopsWhenOffline() = runTest {
        val attempted = mutableListOf<String>()
        val siteErrors = service { entry, _ ->
            attempted += entry.id
            if (entry.id.startsWith("b")) throw TranscriptException.BadStatus(404)
            text
        }
        siteErrors.backfill(listOf("english-Blank-1", "english-Blank-2", "nope-1", bird), allowsCellular = true)
        assertThat(attempted).containsExactly("b1", "b2", "6878dc6679c7824a20c86a2e").inOrder()
        assertThat(siteErrors.cachedIDs.value).containsExactly(bird)

        attempted.clear()
        val offline = service(File(folder.root, "other")) { entry, _ ->
            attempted += entry.id
            throw TranscriptException.Network("offline")
        }
        offline.backfill(listOf("english-Blank-1", "english-Blank-2", bird, geeta), allowsCellular = true)
        assertThat(attempted).hasSize(TranscriptService.BACKFILL_FAILURE_LIMIT)
    }

    @Test
    fun realHindiPageCachesAndReloads() = runTest {
        val directory = File(folder.root, "transcripts")
        val page = Fixtures.read("ashtavakra-maha-geeta-01.page.html")
        val service = service(directory) { _, _ -> checkNotNull(TranscriptFetcher.descriptionFromPageHTML(page)) }
        val loaded = service.transcript(geeta)
        assertThat(loaded.paragraphs).hasSize(239)
        val reread = service(directory) { _, _ -> error("network") }.transcript(geeta)
        assertThat(reread).isEqualTo(loaded)
    }

    @Test
    fun timingUsesShippedStartsOnlyForTheSameSplitAndRecording() = runTest {
        val service = service { _, _ -> "One. $text<br>Two. $text<br>Three. $text" }
        val transcript = service.transcript(bird)
        val empty = TranscriptDiscourseState()

        val shipped = service.timing(transcript, duration = 302.0, state = empty)
        assertThat(shipped.source).isEqualTo(TimingSource.SHIPPED_ALIGNMENT)
        assertThat(shipped.startTime(1)).isWithin(1e-9).of(100.0)
        assertThat(shipped.startTime(2)).isWithin(1e-9).of(200.0)

        val otherRecording = service.timing(transcript, duration = 310.0, state = empty)
        assertThat(otherRecording.source).isEqualTo(TimingSource.ESTIMATE)
        assertThat(service.timing(transcript, duration = 0.0, state = empty).source).isEqualTo(TimingSource.ESTIMATE)

        val resplit = transcript.copy(paragraphs = transcript.paragraphs.take(2))
        assertThat(service.timing(resplit, duration = 300.0, state = empty).source).isEqualTo(TimingSource.ESTIMATE)
    }

    @Test
    fun timingFallsBackToDeviceAlignmentThenEstimateAndAnchorsBendBoth() = runTest {
        val service = service { _, _ -> "$text<br>$text<br>$text<br>$text" }
        val transcript = service.transcript(geeta)
        val device = TranscriptAlignment(starts = listOf(0.0, 50.0, null, 300.0), createdAt = 0L, engine = "test")

        val aligned = service.timing(transcript, 400.0, TranscriptDiscourseState(alignment = device))
        assertThat(aligned.source).isEqualTo(TimingSource.DEVICE_ALIGNMENT)
        assertThat(aligned.startTime(1)).isWithin(1e-9).of(50.0)
        assertThat(aligned.startTime(3)).isWithin(1e-9).of(300.0)

        val wrongCount = device.copy(starts = listOf(0.0, 50.0))
        val estimate = service.timing(transcript, 400.0, TranscriptDiscourseState(alignment = wrongCount))
        assertThat(estimate.source).isEqualTo(TimingSource.ESTIMATE)
        assertThat(estimate.startTime(2)).isWithin(1e-9).of(200.0)

        // An anchor that agrees with the aligned starts adds a knot and keeps them.
        val anchor = TranscriptAnchor(paragraph = 1, time = 250.0, createdAt = 0L)
        val bent = service.timing(transcript, 400.0, TranscriptDiscourseState(anchors = listOf(anchor), alignment = device))
        assertThat(bent.paragraphAt(250.0)).isEqualTo(1)
        assertThat(bent.startTime(3)).isWithin(1e-9).of(300.0)

        // Paragraph 1 heard at 320 s rules out paragraph 3 starting at 300 s; the map bends to the anchor.
        val late = anchor.copy(time = 320.0)
        val overridden = service.timing(transcript, 400.0, TranscriptDiscourseState(anchors = listOf(late), alignment = device))
        assertThat(overridden.startTime(3)).isWithin(1e-9).of(320.0 + (1.5 / 2.5) * 80.0)
        val bentEstimate = service.timing(transcript, 400.0, TranscriptDiscourseState(anchors = listOf(anchor)))
        assertThat(bentEstimate.source).isEqualTo(TimingSource.ESTIMATE)
        assertThat(bentEstimate.time(1, 0.5)).isWithin(1e-9).of(250.0)
    }

    @Test
    fun seriesCountsComeFromTheCatalog() = runTest {
        val service = service { _, _ -> text }
        assertThat(service.transcriptCount("english-Blank")).isEqualTo(2)
        assertThat(service.transcriptCount("english-Nothing")).isEqualTo(0)
    }

    @Test
    fun standardDispatcherWarmUpDoesNotBlockQueries() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val service = TranscriptService(
            directory = File(folder.root, "warm"),
            catalog = lazyOf(catalog),
            alignments = lazyOf(alignments),
            fetchHTML = { _, _ -> text },
            scope = CoroutineScope(SupervisorJob() + dispatcher),
        )
        assertThat(service.availability(bird)).isEqualTo(TranscriptAvailability.NOT_CACHED)
        runCurrent()
        assertThat(service.availability("nope-1")).isEqualTo(TranscriptAvailability.UNAVAILABLE)
    }
}
