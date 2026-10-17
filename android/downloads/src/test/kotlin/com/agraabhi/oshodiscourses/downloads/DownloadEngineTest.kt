package com.agraabhi.oshodiscourses.downloads

import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadError
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadNetwork
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadSource
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadState
import com.agraabhi.oshodiscourses.core.domain.downloads.WaitingReason
import com.agraabhi.oshodiscourses.core.testing.SampleCatalog
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.SocketEffect
import okio.Buffer
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36])
class DownloadEngineTest {
    @get:Rule
    val temp = TemporaryFolder()

    private lateinit var server: MockWebServer
    private val harnesses = mutableListOf<EngineHarness>()

    private val bird = SampleCatalog.birdOnTheWing
    private val bird1 = "english-A_Bird_on_the_Wing__-1"
    private val bird2 = "english-A_Bird_on_the_Wing__-2"
    private val bird3 = "english-A_Bird_on_the_Wing__-3"
    private val geeta1 = "hindi-Maha_Geeta-1"

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
    }

    @After
    fun tearDown() {
        harnesses.forEach { it.close() }
        server.close()
    }

    private fun harness(
        nearOshoworld: Boolean = false,
        allowCellular: Boolean = false,
        network: DownloadNetwork = DownloadNetwork.UNRESTRICTED,
        debugFeatures: Boolean = false,
    ) = EngineHarness(temp.root, server, nearOshoworld, allowCellular, network, debugFeatures = debugFeatures).also { harnesses += it }

    private fun path(source: String, id: String) = "/$source/$id.mp3"

    private suspend fun DownloadEngine.runToIdle() = withTimeout(15_000) { runQueue() }

    // region Layout, manifest, hooks

    @Test
    fun aDownloadLandsInTheIosLayoutWithManifestHistoryAndTranscript() = runBlocking<Unit> {
        val h = harness()
        val bytes = audioBytes(150_000)
        h.dispatcher.enqueue(path("archive", bird1), audioResponse(bytes))
        val engine = h.newEngine()
        engine.awaitReady()

        engine.enqueue(bird1)
        assertThat(h.scheduler.calls).contains(RecordingScheduler.Call(allowCellular = false, replace = false))
        assertThat(engine.runToIdle()).isTrue()

        val file = h.audioFile("A Bird on the Wing", 1)
        assertThat(file.readBytes()).isEqualTo(bytes)
        assertThat(engine.state(bird1)).isEqualTo(DownloadState.Downloaded)
        assertThat(engine.downloadedIDs.value).containsExactly(bird1)
        assertThat(engine.storageUsedBytes.value).isEqualTo(150_000L)
        assertThat(engine.downloadedSizes()).containsExactly(bird1, 150_000L)
        assertThat(engine.localFileURI(bird1)).isEqualTo(file.toURI().toString())

        val manifest = Json.parseToJsonElement(File(h.filesDir, ".download_manifest.json").readText()).jsonObject
        assertThat(manifest[bird1]?.jsonPrimitive?.content).isEqualTo("Osho Discourses/A Bird on the Wing/A Bird on the Wing - #1.mp3")
        val history = Json.parseToJsonElement(File(h.filesDir, ".download_history.json").readText()).jsonArray
        assertThat(history.map { it.jsonPrimitive.content }).containsExactly(bird1)
        assertThat(engine.downloadHistory.value).containsExactly(bird1)

        withTimeout(2_000) { while (bird1 !in h.transcripts.prefetched) delay(10) }
        assertThat(h.dispatcher.paths()).containsExactly(path("archive", bird1))
        assertThat(h.speeds.load()).containsKey(DownloadSource.ARCHIVE)
        assertThat(h.partialDir.listFiles().orEmpty()).isEmpty()
    }

    @Test
    fun aNearListenerTriesOshoworldFirst() = runBlocking<Unit> {
        val h = harness(nearOshoworld = true)
        h.dispatcher.enqueue(path("oshoworld", bird1), audioResponse(audioBytes(10_000)))
        val engine = h.newEngine()
        engine.enqueue(bird1)
        engine.runToIdle()
        assertThat(h.dispatcher.paths()).containsExactly(path("oshoworld", bird1))
        assertThat(engine.state(bird1)).isEqualTo(DownloadState.Downloaded)
    }

    @Test
    fun measuredSpeedOverridesTheRegion() = runBlocking<Unit> {
        val h = harness(nearOshoworld = false)
        h.speeds.save(mapOf(DownloadSource.ARCHIVE to 10_000.0, DownloadSource.OSHOWORLD to 5_000_000.0))
        h.dispatcher.enqueue(path("oshoworld", bird1), audioResponse(audioBytes(10_000)))
        val engine = h.newEngine()
        engine.enqueue(bird1)
        engine.runToIdle()
        assertThat(h.dispatcher.paths()).containsExactly(path("oshoworld", bird1))
    }

    // endregion

    // region Source fallback and error mapping

    @Test
    fun aMissingFileOnTheMirrorFallsBackToOshoworld() = runBlocking<Unit> {
        val h = harness()
        val bytes = audioBytes(20_000)
        h.dispatcher.enqueue(path("oshoworld", bird1), audioResponse(bytes))
        val engine = h.newEngine()
        engine.enqueue(bird1)
        engine.runToIdle()
        assertThat(h.dispatcher.paths()).containsExactly(path("archive", bird1), path("oshoworld", bird1)).inOrder()
        assertThat(h.audioFile("A Bird on the Wing", 1).readBytes()).isEqualTo(bytes)
    }

    @Test
    fun aWebPageFromTheOnlyServerFailsAsNotAudio() = runBlocking<Unit> {
        val h = harness()
        h.catalog.mirrored = false
        h.dispatcher.enqueue(
            path("oshoworld", bird1),
            MockResponse.Builder().code(200).addHeader("Content-Type", "text/html; charset=utf-8").body("<html>Sign in to Wi-Fi</html>").build(),
        )
        val engine = h.newEngine()
        engine.enqueue(bird1)
        engine.runToIdle()
        val state = engine.state(bird1)
        assertThat(state).isEqualTo(DownloadState.Failed(DownloadError.NotAudio))
        assertThat((state as DownloadState.Failed).error.message).isEqualTo("Server returned a web page, not audio.")
        assertThat(h.audioFile("A Bird on the Wing", 1).exists()).isFalse()
        assertThat(engine.downloadedIDs.value).isEmpty()
    }

    @Test
    fun markupLabelledAsAudioIsStillRejected() = runBlocking<Unit> {
        val h = harness()
        h.catalog.mirrored = false
        h.dispatcher.enqueue(
            path("oshoworld", bird1),
            MockResponse.Builder().code(200).addHeader("Content-Type", "audio/mpeg").body("  <!DOCTYPE html><html></html>").build(),
        )
        val engine = h.newEngine()
        engine.enqueue(bird1)
        engine.runToIdle()
        assertThat(engine.state(bird1)).isEqualTo(DownloadState.Failed(DownloadError.NotAudio))
    }

    @Test
    fun aWebPageOnTheMirrorFallsBackToTheOtherServer() = runBlocking<Unit> {
        val h = harness()
        h.dispatcher.enqueue(path("archive", bird1), MockResponse.Builder().code(200).addHeader("Content-Type", "text/html").body("<html/>").build())
        h.dispatcher.enqueue(path("oshoworld", bird1), audioResponse(audioBytes(5_000)))
        val engine = h.newEngine()
        engine.enqueue(bird1)
        engine.runToIdle()
        assertThat(engine.state(bird1)).isEqualTo(DownloadState.Downloaded)
    }

    @Test
    fun serverErrorsAndMissingFilesMapToTheirMessages() = runBlocking<Unit> {
        val h = harness()
        h.catalog.mirrored = false
        h.dispatcher.enqueue(path("oshoworld", bird1), MockResponse.Builder().code(503).build())
        val engine = h.newEngine()
        engine.enqueueAll(listOf(bird1, bird2))
        engine.runToIdle()
        val serverError = engine.state(bird1) as DownloadState.Failed
        assertThat(serverError.error).isEqualTo(DownloadError.ServerError(503))
        assertThat(serverError.error.message).isEqualTo("Server error (HTTP 503).")
        val missing = engine.state(bird2) as DownloadState.Failed
        assertThat(missing.error.message).isEqualTo("Not available on the server (404).")
    }

    @Test
    fun aFailedDownloadCanBeRetried() = runBlocking<Unit> {
        val h = harness()
        h.catalog.mirrored = false
        h.dispatcher.enqueue(path("oshoworld", bird1), MockResponse.Builder().code(500).build(), audioResponse(audioBytes(4_000)))
        val engine = h.newEngine()
        engine.enqueue(bird1)
        engine.runToIdle()
        assertThat(engine.state(bird1)).isInstanceOf(DownloadState.Failed::class.java)
        engine.enqueue(bird1)
        assertThat(engine.state(bird1)).isInstanceOf(DownloadState.Downloading::class.java)
        engine.runToIdle()
        assertThat(engine.state(bird1)).isEqualTo(DownloadState.Downloaded)
    }

    @Test
    fun fullStorageFailsWithoutTryingTheOtherServer() = runBlocking<Unit> {
        val h = harness()
        h.freeSpace = 1_000
        h.dispatcher.enqueue(path("archive", bird1), audioResponse(audioBytes(50_000)))
        h.dispatcher.enqueue(path("oshoworld", bird1), audioResponse(audioBytes(50_000)))
        val engine = h.newEngine()
        engine.enqueue(bird1)
        engine.runToIdle()
        val failed = engine.state(bird1) as DownloadState.Failed
        assertThat(failed.error).isEqualTo(DownloadError.DiskFull)
        assertThat(failed.error.message).isEqualTo("Not enough storage on your device.")
        assertThat(h.dispatcher.paths()).containsExactly(path("archive", bird1))
    }

    // endregion

    // region Resume and stalls

    @Test
    fun aDroppedConnectionResumesWithRange() = runBlocking<Unit> {
        val h = harness()
        h.catalog.mirrored = false
        val bytes = audioBytes(120_000)
        val half = 50_000
        val dropped = MockResponse.Builder()
            .code(200)
            .addHeader("Content-Type", "audio/mpeg")
            .addHeader("ETag", "\"v7\"")
            .body(Buffer().write(bytes, 0, half))
            .setHeader("Content-Length", bytes.size)
            .onResponseEnd(SocketEffect.ShutdownConnection)
            .build()
        val rest = MockResponse.Builder()
            .code(206)
            .addHeader("Content-Type", "audio/mpeg")
            .addHeader("Content-Range", "bytes $half-${bytes.size - 1}/${bytes.size}")
            .body(Buffer().write(bytes, half, bytes.size - half))
            .build()
        h.dispatcher.enqueue(path("oshoworld", bird1), dropped, rest)
        val engine = h.newEngine()
        engine.enqueue(bird1)
        engine.runToIdle()

        assertThat(engine.state(bird1)).isEqualTo(DownloadState.Downloaded)
        assertThat(h.audioFile("A Bird on the Wing", 1).readBytes()).isEqualTo(bytes)
        val resumed = h.dispatcher.requests[1]
        assertThat(resumed.headers["Range"]).isEqualTo("bytes=$half-")
        assertThat(resumed.headers["If-Range"]).isEqualTo("\"v7\"")
        assertThat(h.dispatcher.requests[0].headers["Range"]).isNull()
    }

    @Test
    fun aServerThatIgnoresTheRangeStartsOver() = runBlocking<Unit> {
        val h = harness()
        h.catalog.mirrored = false
        val bytes = audioBytes(60_000)
        val dropped = MockResponse.Builder()
            .code(200)
            .addHeader("Content-Type", "audio/mpeg")
            .addHeader("ETag", "\"v1\"")
            .body(Buffer().write(bytes, 0, 20_000))
            .setHeader("Content-Length", bytes.size)
            .onResponseEnd(SocketEffect.ShutdownConnection)
            .build()
        h.dispatcher.enqueue(path("oshoworld", bird1), dropped, audioResponse(bytes))
        val engine = h.newEngine()
        engine.enqueue(bird1)
        engine.runToIdle()
        assertThat(h.audioFile("A Bird on the Wing", 1).readBytes()).isEqualTo(bytes)
    }

    @Test
    fun aFrozenServerIsAbandonedAfterItsRestartAndTheOtherIsTried() = runBlocking<Unit> {
        val h = harness()
        val bytes = audioBytes(80_000)
        // Headers promise the whole file, then the mirror goes silent.
        fun frozen() = MockResponse.Builder()
            .code(200)
            .addHeader("Content-Type", "audio/mpeg")
            .body(Buffer().write(bytes, 0, 10_000))
            .setHeader("Content-Length", bytes.size)
            .build()
        h.dispatcher.enqueue(path("archive", bird1), frozen(), frozen())
        h.dispatcher.enqueue(path("oshoworld", bird1), audioResponse(bytes))
        val engine = h.newEngine()
        engine.enqueue(bird1)
        engine.runToIdle()

        assertThat(engine.state(bird1)).isEqualTo(DownloadState.Downloaded)
        assertThat(h.dispatcher.paths()).containsExactly(path("archive", bird1), path("archive", bird1), path("oshoworld", bird1)).inOrder()
        // The frozen server's measured speed drops so the next download prefers the other one.
        assertThat(h.speeds.load()[DownloadSource.ARCHIVE]).isEqualTo(0.0)
    }

    @Test
    fun aFrozenOnlyServerFailsAsStalledAfterTwoRestarts() = runBlocking<Unit> {
        val h = harness()
        h.catalog.mirrored = false
        val bytes = audioBytes(40_000)
        fun frozen() = MockResponse.Builder()
            .code(200)
            .addHeader("Content-Type", "audio/mpeg")
            .body(Buffer().write(bytes, 0, 1_000))
            .setHeader("Content-Length", bytes.size)
            .build()
        h.dispatcher.enqueue(path("oshoworld", bird1), frozen(), frozen(), frozen())
        val engine = h.newEngine()
        engine.enqueue(bird1)
        engine.runToIdle()
        assertThat(engine.state(bird1)).isEqualTo(DownloadState.Failed(DownloadError.Stalled))
        assertThat(h.dispatcher.paths()).hasSize(3)
    }

    // endregion

    // region Network rules

    @Test
    fun onMobileDataWithCellularOffItWaitsForWifiUntilUseMobileData() = runBlocking<Unit> {
        val h = harness(network = DownloadNetwork.CELLULAR_ONLY)
        h.dispatcher.enqueue(path("archive", bird1), audioResponse(audioBytes(8_000)))
        val engine = h.newEngine()
        engine.enqueueAll(listOf(bird1, bird2))
        assertThat(engine.state(bird1)).isEqualTo(DownloadState.WaitingForWifi)
        assertThat(engine.state(bird2)).isEqualTo(DownloadState.Queued)
        assertThat(engine.waitingReason.value).isEqualTo(WaitingReason.WIFI)
        assertThat(engine.network.value).isEqualTo(DownloadNetwork.CELLULAR_ONLY)

        val run = async { engine.runToIdle() }
        delay(300)
        assertThat(server.requestCount).isEqualTo(0)

        engine.useMobileData()
        assertThat(h.settings.settings.value.allowCellularDownloads).isTrue()
        assertThat(h.scheduler.calls).contains(RecordingScheduler.Call(allowCellular = true, replace = true))
        run.await()
        assertThat(engine.state(bird1)).isEqualTo(DownloadState.Downloaded)
        assertThat(engine.waitingReason.value).isNull()
    }

    @Test
    fun turningCellularOffInSettingsReplacesTheHost() = runBlocking<Unit> {
        val h = harness(allowCellular = true, network = DownloadNetwork.CELLULAR_ONLY)
        val engine = h.newEngine()
        engine.enqueue(bird1)
        assertThat(engine.state(bird1)).isInstanceOf(DownloadState.Downloading::class.java)
        h.settings.setAllowCellularDownloads(false)
        engine.states.awaitValue { it[bird1] == DownloadState.WaitingForWifi }
        withTimeout(2_000) { while (RecordingScheduler.Call(false, true) !in h.scheduler.calls) delay(10) }
    }

    @Test
    fun offlineWaitsForAConnection() = runBlocking<Unit> {
        val h = harness(network = DownloadNetwork.OFFLINE)
        h.dispatcher.enqueue(path("archive", bird1), audioResponse(audioBytes(8_000)))
        val engine = h.newEngine()
        engine.enqueue(bird1)
        assertThat(engine.state(bird1)).isEqualTo(DownloadState.WaitingForConnection)
        assertThat(engine.waitingReason.value).isEqualTo(WaitingReason.CONNECTION)
        val run = async { engine.runToIdle() }
        delay(200)
        assertThat(server.requestCount).isEqualTo(0)
        h.network.network.value = DownloadNetwork.UNRESTRICTED
        run.await()
        assertThat(engine.state(bird1)).isEqualTo(DownloadState.Downloaded)
    }

    @Test
    fun losingWiFiMidTransferPausesAndResumesWithoutFailing() = runBlocking<Unit> {
        val h = harness()
        h.catalog.mirrored = false
        val bytes = audioBytes(200_000)
        val slow = MockResponse.Builder()
            .code(200)
            .addHeader("Content-Type", "audio/mpeg")
            .addHeader("ETag", "\"slow\"")
            .body(Buffer().write(bytes))
            .throttleBody(8_000, 50, TimeUnit.MILLISECONDS)
            .build()
        h.dispatcher.enqueue(path("oshoworld", bird1), slow)
        val engine = h.newEngine()
        engine.enqueue(bird1)
        val run = async { engine.runToIdle() }
        engine.states.awaitValue { (it[bird1] as? DownloadState.Downloading)?.bytesDownloaded?.let { b -> b > 0 } == true }

        h.network.network.value = DownloadNetwork.CELLULAR_ONLY
        engine.states.awaitValue { it[bird1] == DownloadState.WaitingForWifi }
        val partial = File(h.partialDir, "english-A_Bird_on_the_Wing__-1.part")
        // Let the cancelled read settle so the size below is what the resume will ask for.
        delay(300)
        withTimeout(2_000) { while (!partial.exists() || partial.length() == 0L) delay(10) }
        val kept = partial.length()
        val remaining = bytes.size - kept.toInt()
        h.dispatcher.enqueue(
            path("oshoworld", bird1),
            MockResponse.Builder()
                .code(206)
                .addHeader("Content-Type", "audio/mpeg")
                .addHeader("Content-Range", "bytes $kept-${bytes.size - 1}/${bytes.size}")
                .body(Buffer().write(bytes, kept.toInt(), remaining))
                .build(),
        )
        delay(100)
        h.network.network.value = DownloadNetwork.UNRESTRICTED
        run.await()

        assertThat(engine.state(bird1)).isEqualTo(DownloadState.Downloaded)
        assertThat(h.audioFile("A Bird on the Wing", 1).readBytes()).isEqualTo(bytes)
        assertThat(h.dispatcher.requests.last().headers["Range"]).isEqualTo("bytes=$kept-")
    }

    @Test
    fun theDebugNetworkArgumentFakesTheNetworkOnlyInDebugBuilds() = runBlocking<Unit> {
        val release = harness().newEngine()
        release.applyDebugNetworkArgument("offline")
        assertThat(release.network.value).isEqualTo(DownloadNetwork.UNRESTRICTED)

        val h = harness(debugFeatures = true)
        val engine = h.newEngine()
        engine.enqueue(bird1)
        engine.applyDebugNetworkArgument("cellularOnly")
        engine.states.awaitValue { it[bird1] == DownloadState.WaitingForWifi }
        assertThat(engine.network.value).isEqualTo(DownloadNetwork.CELLULAR_ONLY)
        engine.applyDebugNetworkArgument("offline")
        engine.states.awaitValue { it[bird1] == DownloadState.WaitingForConnection }

        // Held: even with mobile data allowed, nothing is fetched while the network is faked.
        engine.applyDebugNetworkArgument("cellularOnly")
        engine.useMobileData()
        val run = async { engine.runToIdle() }
        delay(300)
        assertThat(server.requestCount).isEqualTo(0)
        engine.cancel(bird1)
        assertThat(run.await()).isTrue()
    }

    // endregion

    // region Queue, cancel, delete

    @Test
    fun theQueueRunsInRequestOrderOneAtATime() = runBlocking<Unit> {
        val h = harness()
        listOf(bird1, bird2, bird3).forEach { h.dispatcher.enqueue(path("archive", it), audioResponse(audioBytes(6_000, it.hashCode()))) }
        val engine = h.newEngine()
        engine.enqueueAll(listOf(bird3, bird1, bird2))
        engine.enqueue(bird1)
        assertThat(engine.inProgressIDs()).containsExactly(bird3, bird1, bird2).inOrder()
        assertThat(engine.state(bird3)).isInstanceOf(DownloadState.Downloading::class.java)
        assertThat(engine.state(bird1)).isEqualTo(DownloadState.Queued)
        assertThat(engine.state(bird1).isActive).isTrue()
        engine.runToIdle()
        assertThat(h.dispatcher.paths()).containsExactly(path("archive", bird3), path("archive", bird1), path("archive", bird2)).inOrder()
        assertThat(engine.inProgressIDs()).isEmpty()
        assertThat(engine.downloadedIDs.value).containsExactly(bird1, bird2, bird3)
    }

    @Test
    fun enqueueSkipsDownloadedAndUnknownDiscourses() = runBlocking<Unit> {
        val h = harness()
        h.dispatcher.enqueue(path("archive", bird1), audioResponse(audioBytes(3_000)))
        val engine = h.newEngine()
        engine.enqueue(bird1)
        engine.runToIdle()
        h.scheduler.calls.clear()
        engine.enqueueAll(listOf(bird1, "english-Nope-1"))
        assertThat(engine.inProgressIDs()).isEmpty()
        assertThat(h.scheduler.calls).isEmpty()
    }

    @Test
    fun cancelStopsTheTransferAndKeepsNoBytes() = runBlocking<Unit> {
        val h = harness()
        h.catalog.mirrored = false
        val slow = MockResponse.Builder()
            .code(200)
            .addHeader("Content-Type", "audio/mpeg")
            .body(Buffer().write(audioBytes(400_000)))
            .throttleBody(8_000, 50, TimeUnit.MILLISECONDS)
            .build()
        h.dispatcher.enqueue(path("oshoworld", bird1), slow)
        h.dispatcher.enqueue(path("oshoworld", bird2), audioResponse(audioBytes(2_000)))
        val engine = h.newEngine()
        engine.enqueueAll(listOf(bird1, bird2))
        val run = async { engine.runToIdle() }
        engine.states.awaitValue { (it[bird1] as? DownloadState.Downloading)?.bytesDownloaded?.let { b -> b > 0 } == true }
        engine.cancel(bird1)
        assertThat(engine.state(bird1)).isEqualTo(DownloadState.NotDownloaded)
        run.await()
        assertThat(engine.state(bird2)).isEqualTo(DownloadState.Downloaded)
        assertThat(engine.state(bird1)).isEqualTo(DownloadState.NotDownloaded)
        assertThat(h.audioFile("A Bird on the Wing", 1).exists()).isFalse()
        assertThat(h.partialDir.listFiles().orEmpty().filter { it.name.contains("-1.") }).isEmpty()
    }

    @Test
    fun cancellingTheLastQueuedDownloadDropsTheWaitingHost() = runBlocking<Unit> {
        val h = harness(network = DownloadNetwork.OFFLINE)
        val engine = h.newEngine()
        engine.enqueueAll(listOf(bird1, bird2))
        engine.cancel(bird1)
        assertThat(h.scheduler.cancelledPending).isEqualTo(0)
        engine.cancel(bird2)
        assertThat(h.scheduler.cancelledPending).isEqualTo(1)
        assertThat(engine.states.value).isEmpty()
        assertThat(engine.waitingReason.value).isNull()
    }

    @Test
    fun comingToTheForegroundReschedulesAQueueLeftWithoutAHost() = runBlocking<Unit> {
        val h = harness()
        DownloadStore(h.filesDir, h.partialDir).saveQueue(listOf(bird1))
        val engine = h.newEngine()
        engine.awaitReady()
        withTimeout(2_000) { while (h.scheduler.calls.isEmpty()) delay(10) }
        h.scheduler.calls.clear()
        engine.resumePendingTransfers()
        withTimeout(2_000) { while (h.scheduler.calls.isEmpty()) delay(10) }
        assertThat(h.scheduler.calls.single()).isEqualTo(RecordingScheduler.Call(allowCellular = false, replace = false))
    }

    @Test
    fun deleteRemovesFilesEmptyFoldersAndTranscriptsButKeepsHistory() = runBlocking<Unit> {
        val h = harness()
        listOf(bird1, bird2, geeta1).forEach { h.dispatcher.enqueue(path("archive", it), audioResponse(audioBytes(1_000 + it.length))) }
        val engine = h.newEngine()
        engine.enqueueAll(listOf(bird1, bird2, geeta1))
        engine.runToIdle()
        assertThat(engine.downloadedSizes().keys).containsExactly(bird1, bird2, geeta1)

        engine.delete(bird1)
        assertThat(h.audioFile("A Bird on the Wing", 1).exists()).isFalse()
        assertThat(h.audioFile("A Bird on the Wing", 2).exists()).isTrue()
        assertThat(engine.localFileURI(bird1)).isNull()

        engine.deleteSeries(bird.id)
        assertThat(File(h.filesDir, "Osho Discourses/A Bird on the Wing").exists()).isFalse()
        assertThat(engine.downloadedIDs.value).containsExactly(geeta1)
        assertThat(h.transcripts.removed).containsExactly(bird1, bird2)

        engine.deleteAll()
        assertThat(engine.downloadedIDs.value).isEmpty()
        assertThat(engine.storageUsedBytes.value).isEqualTo(0L)
        assertThat(engine.states.value).isEmpty()
        assertThat(engine.downloadHistory.value).containsExactly(bird1, bird2, geeta1)
        val manifest = Json.parseToJsonElement(File(h.filesDir, ".download_manifest.json").readText()).jsonObject
        assertThat(manifest).isEmpty()
    }

    // endregion

    // region History

    @Test
    fun downloadHistoryMergeUnionsAndReportsChange() = runBlocking<Unit> {
        val engine = harness().newEngine()
        assertThat(engine.mergeSyncedDownloadHistory(listOf("a", "b"))).isTrue()
        assertThat(engine.downloadHistory.value).containsAtLeast("a", "b")
        assertThat(engine.mergeSyncedDownloadHistory(listOf("a", "b"))).isFalse()
        assertThat(engine.mergeSyncedDownloadHistory(emptyList())).isFalse()
        assertThat(engine.downloadHistory.value).containsAtLeast("a", "b")
        assertThat(engine.syncedDownloadHistory()).containsExactly("a", "b")
    }

    @Test
    fun forgetDownloadHistoryDropsSelectedIDsButNotDownloadedOnes() = runBlocking<Unit> {
        val h = harness()
        h.dispatcher.enqueue(path("archive", bird1), audioResponse(audioBytes(1_000)))
        val engine = h.newEngine()
        engine.enqueue(bird1)
        engine.runToIdle()
        engine.mergeSyncedDownloadHistory(listOf("a", "b"))
        engine.forgetDownloadHistory(listOf("a", bird1, "never-existed"))
        assertThat(engine.downloadHistory.value).containsExactly(bird1, "b")
        // Survives relaunch.
        assertThat(h.newEngine().also { it.awaitReady() }.downloadHistory.value).containsExactly(bird1, "b")
    }

    // endregion

    // region Recovery after process death

    @Test
    fun manifestRecoveryDropsMissingFilesAndAdoptsOrphans() = runBlocking<Unit> {
        val h = harness()
        h.filesDir.mkdirs()
        File(h.filesDir, ".download_manifest.json").writeText(
            """{"$bird1": "Osho Discourses/A Bird on the Wing/A Bird on the Wing - #1.mp3"}""",
        )
        val orphan = h.audioFile("A Bird on the Wing", 2)
        orphan.parentFile!!.mkdirs()
        orphan.writeBytes(audioBytes(4_321))

        val engine = h.newEngine()
        engine.awaitReady()
        assertThat(engine.downloadedIDs.value).containsExactly(bird2)
        assertThat(engine.storageUsedBytes.value).isEqualTo(4_321L)
        assertThat(engine.downloadHistory.value).containsExactly(bird2)
        val manifest = Json.parseToJsonElement(File(h.filesDir, ".download_manifest.json").readText()).jsonObject
        assertThat(manifest.keys).containsExactly(bird2)
    }

    @Test
    fun aDamagedManifestStartsEmptyInsteadOfCrashing() = runBlocking<Unit> {
        val h = harness()
        h.filesDir.mkdirs()
        File(h.filesDir, ".download_manifest.json").writeText("{not json")
        val engine = h.newEngine()
        engine.awaitReady()
        assertThat(engine.downloadedIDs.value).isEmpty()
    }

    @Test
    fun aQueuedTransferSurvivesProcessDeathAndResumesFromItsPartialFile() = runBlocking<Unit> {
        val h = harness()
        h.catalog.mirrored = false
        val bytes = audioBytes(90_000)
        val kept = 30_000
        val url = server.url(path("oshoworld", bird1)).toString()
        val store = DownloadStore(h.filesDir, h.partialDir)
        store.saveQueue(listOf(bird1, bird2))
        store.partial(bird1).apply {
            writeMeta(PartialMeta(bird1, url, "\"v9\"", bytes.size.toLong()))
            dataFile.writeBytes(bytes.copyOf(kept))
        }
        h.dispatcher.enqueue(
            path("oshoworld", bird1),
            MockResponse.Builder()
                .code(206)
                .addHeader("Content-Type", "audio/mpeg")
                .addHeader("Content-Range", "bytes $kept-${bytes.size - 1}/${bytes.size}")
                .body(Buffer().write(bytes, kept, bytes.size - kept))
                .build(),
        )
        h.dispatcher.enqueue(path("oshoworld", bird2), audioResponse(audioBytes(1_000)))

        val engine = h.newEngine()
        engine.awaitReady()
        val head = engine.state(bird1) as DownloadState.Downloading
        assertThat(head.bytesDownloaded).isEqualTo(kept.toLong())
        assertThat(head.progress).isWithin(0.001).of(kept.toDouble() / bytes.size)
        assertThat(engine.state(bird2)).isEqualTo(DownloadState.Queued)
        withTimeout(2_000) { while (h.scheduler.calls.isEmpty()) delay(10) }
        assertThat(h.scheduler.calls.first()).isEqualTo(RecordingScheduler.Call(allowCellular = false, replace = false))

        engine.runToIdle()
        assertThat(h.audioFile("A Bird on the Wing", 1).readBytes()).isEqualTo(bytes)
        assertThat(h.dispatcher.requests.first().headers["Range"]).isEqualTo("bytes=$kept-")
        assertThat(h.dispatcher.requests.first().headers["If-Range"]).isEqualTo("\"v9\"")
        assertThat(engine.downloadedIDs.value).containsExactly(bird1, bird2)
    }

    @Test
    fun aTransferThatFinishedWhileNoProcessWaitedIsCommitted() = runBlocking<Unit> {
        val h = harness()
        val bytes = audioBytes(7_000)
        DownloadStore(h.filesDir, h.partialDir).partial(bird3).apply {
            writeMeta(PartialMeta(bird3, "https://example.invalid/x.mp3", null, bytes.size.toLong()))
            dataFile.writeBytes(bytes)
        }
        val engine = h.newEngine()
        engine.awaitReady()
        assertThat(engine.state(bird3)).isEqualTo(DownloadState.Downloaded)
        assertThat(h.audioFile("A Bird on the Wing", 3).readBytes()).isEqualTo(bytes)
        withTimeout(2_000) { while (bird3 !in h.transcripts.prefetched) delay(10) }
    }

    @Test
    fun aFinishedDuplicateOfACommittedDownloadIsDiscarded() = runBlocking<Unit> {
        val h = harness()
        val original = h.audioFile("A Bird on the Wing", 1)
        original.parentFile!!.mkdirs()
        original.writeBytes(audioBytes(2_000, seed = 1))
        DownloadStore(h.filesDir, h.partialDir).saveManifest(mapOf(bird1 to DownloadStore.relativePath("A Bird on the Wing", 1)))
        val partial = DownloadStore(h.filesDir, h.partialDir).partial(bird1).apply {
            writeMeta(PartialMeta(bird1, "https://example.invalid/x.mp3", null, 3_000))
            dataFile.writeBytes(audioBytes(3_000, seed = 2))
        }
        val engine = h.newEngine()
        engine.awaitReady()
        assertThat(partial.dataFile.exists()).isFalse()
        assertThat(original.readBytes()).isEqualTo(audioBytes(2_000, seed = 1))
        assertThat(engine.state(bird1)).isEqualTo(DownloadState.Downloaded)
    }

    @Test
    fun anUnfinishedPartialNoLongerQueuedIsDeleted() = runBlocking<Unit> {
        val h = harness()
        val partial = DownloadStore(h.filesDir, h.partialDir).partial(bird2).apply {
            writeMeta(PartialMeta(bird2, "https://example.invalid/x.mp3", null, 10_000))
            dataFile.writeBytes(audioBytes(500))
        }
        val engine = h.newEngine()
        engine.awaitReady()
        assertThat(partial.dataFile.exists()).isFalse()
        assertThat(engine.state(bird2)).isEqualTo(DownloadState.NotDownloaded)
    }

    @Test
    fun aFileAlreadyInTheLibraryIsRecordedWithoutDownloading() = runBlocking<Unit> {
        val h = harness()
        val engine = h.newEngine()
        engine.awaitReady()
        engine.enqueue(bird1)
        val seeded = h.audioFile("A Bird on the Wing", 1)
        seeded.parentFile!!.mkdirs()
        seeded.writeBytes(audioBytes(1_234))
        engine.runToIdle()
        assertThat(server.requestCount).isEqualTo(0)
        assertThat(engine.state(bird1)).isEqualTo(DownloadState.Downloaded)
        assertThat(engine.downloadedSizes()).containsExactly(bird1, 1_234L)
    }

    @Test
    fun localFileURIEvictsAFileDeletedBehindTheAppsBack() = runBlocking<Unit> {
        val h = harness()
        h.dispatcher.enqueue(path("archive", bird1), audioResponse(audioBytes(1_000)))
        val engine = h.newEngine()
        engine.enqueue(bird1)
        engine.runToIdle()
        h.audioFile("A Bird on the Wing", 1).delete()
        assertThat(engine.localFileURI(bird1)).isNull()
        engine.downloadedIDs.awaitValue { bird1 !in it }
    }

    // endregion
}
