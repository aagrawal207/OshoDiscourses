package com.agraabhi.oshodiscourses.downloads

import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadNetwork
import com.agraabhi.oshodiscourses.core.domain.settings.UserSettings
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptRepository
import com.agraabhi.oshodiscourses.core.model.CatalogDiscourse
import com.agraabhi.oshodiscourses.core.model.CatalogEntry
import com.agraabhi.oshodiscourses.core.model.CatalogRepository
import com.agraabhi.oshodiscourses.core.testing.FakeCatalogRepository
import com.agraabhi.oshodiscourses.core.testing.FakeSettingsRepository
import com.agraabhi.oshodiscourses.core.testing.FakeTranscriptRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeout
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okhttp3.OkHttpClient
import okio.Buffer
import java.io.File
import java.util.Collections
import java.util.concurrent.TimeUnit
import kotlin.random.Random

/** Sample catalog whose audio lives on [server]: `/oshoworld/<id>.mp3` and, when mirrored, `/archive/<id>.mp3`. */
class ServerCatalog(
    private val server: MockWebServer,
    var mirrored: Boolean = true,
    private val base: FakeCatalogRepository = FakeCatalogRepository(),
) : CatalogRepository by base {
    override fun entry(discourseID: String): CatalogEntry? = base.entry(discourseID)?.let {
        it.copy(discourse = it.discourse.copy(audioURL = server.url("/oshoworld/${it.discourse.id}.mp3").toString()))
    }

    override fun archiveAudioURL(discourse: CatalogDiscourse): String? =
        if (mirrored) server.url("/archive/${discourse.id}.mp3").toString() else null
}

/** Serves queued responses per path, in order; anything unplanned is a 404. */
class RoutingDispatcher : Dispatcher() {
    private val routes = HashMap<String, ArrayDeque<MockResponse>>()
    val requests: MutableList<RecordedRequest> = Collections.synchronizedList(mutableListOf())

    @Synchronized
    fun enqueue(path: String, vararg responses: MockResponse) {
        routes.getOrPut(path) { ArrayDeque() }.addAll(responses)
    }

    override fun dispatch(request: RecordedRequest): MockResponse {
        requests += request
        val path = request.url.encodedPath
        return synchronized(this) { routes[path]?.removeFirstOrNull() } ?: MockResponse.Builder().code(404).build()
    }

    fun paths(): List<String> = synchronized(requests) { requests.map { it.url.encodedPath } }
}

class RecordingScheduler : TransferScheduler {
    data class Call(val allowCellular: Boolean, val replace: Boolean)

    val calls: MutableList<Call> = Collections.synchronizedList(mutableListOf())

    @Volatile
    var cancelledPending: Int = 0

    override fun schedule(allowCellular: Boolean, estimatedBytes: Long, replace: Boolean) {
        calls += Call(allowCellular, replace)
    }

    override fun cancelPending() {
        cancelledPending++
    }
}

class RecordingTranscripts(private val base: FakeTranscriptRepository = FakeTranscriptRepository()) : TranscriptRepository by base {
    val prefetched: MutableList<String> = Collections.synchronizedList(mutableListOf())
    val removed: MutableList<String> = Collections.synchronizedList(mutableListOf())

    override suspend fun prefetch(discourseID: String, allowsCellular: Boolean) {
        prefetched += discourseID
    }

    override suspend fun remove(discourseID: String) {
        removed += discourseID
    }
}

class TestNetwork(initial: DownloadNetwork = DownloadNetwork.UNRESTRICTED) : NetworkMonitor {
    override val network = MutableStateFlow(initial)
}

/** One engine over a temp directory and a MockWebServer, recreated to simulate process death. */
class EngineHarness(
    val root: File,
    val server: MockWebServer,
    var nearOshoworld: Boolean = false,
    allowCellular: Boolean = false,
    initialNetwork: DownloadNetwork = DownloadNetwork.UNRESTRICTED,
    var freeSpace: Long = Long.MAX_VALUE,
    val stallThresholdMillis: Long = 400,
    val debugFeatures: Boolean = false,
) {
    val dispatcher = RoutingDispatcher().also { server.dispatcher = it }
    val catalog = ServerCatalog(server)
    val settings = FakeSettingsRepository(UserSettings(allowCellularDownloads = allowCellular))
    val network = TestNetwork(initialNetwork)
    val scheduler = RecordingScheduler()
    val transcripts = RecordingTranscripts()
    val speeds = InMemorySpeedStore()
    val filesDir = File(root, "files")
    val partialDir = File(root, "partial")
    private val scopes = mutableListOf<CoroutineScope>()

    val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(2, TimeUnit.SECONDS)
        .readTimeout(5, TimeUnit.SECONDS)
        .build()

    fun newEngine(): DownloadEngine {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        scopes += scope
        return DownloadEngine(
            store = DownloadStore(filesDir, partialDir),
            catalog = catalog,
            settings = settings,
            transcripts = transcripts,
            networkMonitor = network,
            scheduler = scheduler,
            speedStore = speeds,
            httpClient = client,
            transfer = HttpTransfer(stallThresholdMillis = stallThresholdMillis, freeSpace = { freeSpace }),
            isNearOshoworld = { nearOshoworld },
            scope = scope,
            debugFeaturesEnabled = debugFeatures,
            fileUri = { it.toURI().toString() },
        )
    }

    fun audioFile(seriesName: String, number: Int): File = File(filesDir, DownloadStore.relativePath(seriesName, number))

    fun close() {
        scopes.forEach { it.cancel() }
    }
}

fun audioBytes(size: Int, seed: Int = size): ByteArray {
    val bytes = Random(seed).nextBytes(size)
    "ID3".toByteArray().copyInto(bytes)
    return bytes
}

fun audioResponse(bytes: ByteArray, etag: String = "\"v1\""): MockResponse = MockResponse.Builder()
    .code(200)
    .addHeader("Content-Type", "audio/mpeg")
    .addHeader("ETag", etag)
    .body(Buffer().write(bytes))
    .build()

suspend fun <T> StateFlow<T>.awaitValue(timeoutMillis: Long = 5_000, predicate: (T) -> Boolean): T =
    withTimeout(timeoutMillis) { first(predicate) }
