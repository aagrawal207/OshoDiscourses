package com.agraabhi.oshodiscourses.transcript

import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptException
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.test.runTest
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.OkHttpClient
import org.junit.After
import org.junit.Before
import org.junit.Test
import kotlin.test.assertFailsWith

class TranscriptFetcherTest {
    private val server = MockWebServer()
    private val entry = TranscriptCatalog.Entry(id = "6878dc6679c7824a20c86a2e", slug = "a-bird-on-the-wing-01", words = 8771)

    @Before
    fun setUp() = server.start()

    @After
    fun tearDown() = server.close()

    private fun fetcher(cellularOnly: Boolean = false): TranscriptFetcher {
        val base = server.url("/").toString().trimEnd('/')
        return TranscriptFetcher(OkHttpClient(), isCellularOnly = { cellularOnly }, apiBase = "$base/api/server", siteBase = base)
    }

    private fun respond(code: Int, body: String) = server.enqueue(MockResponse.Builder().code(code).body(body).build())

    @Test
    fun apiResponseYieldsDescriptionOrNull() {
        assertThat(TranscriptFetcher.descriptionFromAPIResponse("""{"description":"<b>Hi</b>"}""")).isEqualTo("<b>Hi</b>")
        assertThat(TranscriptFetcher.descriptionFromAPIResponse("""{"error":true}""")).isNull()
        assertThat(TranscriptFetcher.descriptionFromAPIResponse("not json")).isNull()
        assertThat(TranscriptFetcher.descriptionFromAPIResponse("""{"description":null}""")).isNull()
        assertThat(TranscriptFetcher.descriptionFromAPIResponse(Fixtures.read("error.api.json"))).isNull()
    }

    @Test
    fun nextDataIsDugOutOfThePage() {
        val page = """
            <html><body><div>x</div><script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"data":{"pageData":{"audioData":{"title":"T","description":"line one<br>line two"}}}}},"page":"/[[...index]]"}</script></body></html>
        """.trimIndent()
        assertThat(TranscriptFetcher.descriptionFromPageHTML(page)).isEqualTo("line one<br>line two")
        assertThat(TranscriptFetcher.descriptionFromPageHTML("<html></html>")).isNull()
        assertThat(TranscriptFetcher.descriptionFromPageHTML("""<script id="__NEXT_DATA__" type="application/json">{"props":{}}</script>""")).isNull()
    }

    @Test
    fun realPayloadsCarryTheTranscript() {
        val english = TranscriptFetcher.descriptionFromAPIResponse(Fixtures.read("a-bird-on-the-wing-01.api.json"))
        assertThat(english).startsWith("<strong>BELOVED MASTER,</strong><br>")
        val hindi = TranscriptFetcher.descriptionFromPageHTML(Fixtures.read("ashtavakra-maha-geeta-01.page.html"))
        assertThat(hindi).startsWith("जनक उवाच।<br><br>")
        assertThat(hindi).endsWith("<hr>")
    }

    @Test
    fun apiIsTriedFirstWithTheSiteHeader() = runTest {
        respond(200, Fixtures.read("a-bird-on-the-wing-01.api.json"))
        val html = fetcher().fetchDescriptionHTML(entry, allowsCellular = true)
        assertThat(html).startsWith("<strong>BELOVED MASTER,")
        val request = server.takeRequest()
        assertThat(request.url.encodedPath).isEqualTo("/api/server/audio/get-description/6878dc6679c7824a20c86a2e")
        assertThat(request.headers["Content-type"]).isEqualTo("application/json")
        assertThat(server.requestCount).isEqualTo(1)
    }

    @Test
    fun errorPayloadFallsBackToThePage() = runTest {
        respond(200, Fixtures.read("error.api.json"))
        respond(200, Fixtures.read("ashtavakra-maha-geeta-01.page.html"))
        val html = fetcher().fetchDescriptionHTML(entry, allowsCellular = true)
        assertThat(html).startsWith("जनक उवाच।")
        server.takeRequest()
        assertThat(server.takeRequest().url.encodedPath).isEqualTo("/a-bird-on-the-wing-01")
    }

    @Test
    fun badApiStatusFallsBackAndIsReportedWhenThePageHasNoData() = runTest {
        respond(503, "")
        respond(200, "<html></html>")
        val error = assertFailsWith<TranscriptException.BadStatus> { fetcher().fetchDescriptionHTML(entry, allowsCellular = true) }
        assertThat(error.code).isEqualTo(503)
        assertThat(error.isRetryable).isFalse()
    }

    @Test
    fun pageWithoutDataAfterAnEmptyApiAnswerIsNoDescription() = runTest {
        respond(200, "{}")
        respond(200, "<html></html>")
        assertFailsWith<TranscriptException.NoDescription> { fetcher().fetchDescriptionHTML(entry, allowsCellular = true) }
    }

    @Test
    fun pageStatusErrorWins() = runTest {
        respond(200, "{}")
        respond(404, "")
        val error = assertFailsWith<TranscriptException.BadStatus> { fetcher().fetchDescriptionHTML(entry, allowsCellular = true) }
        assertThat(error.code).isEqualTo(404)
    }

    @Test
    fun transportFailureIsRetryable() = runTest {
        val dead = fetcher()
        server.close()
        val error = assertFailsWith<TranscriptException.Network> { dead.fetchDescriptionHTML(entry, allowsCellular = true) }
        assertThat(error.isRetryable).isTrue()
    }

    @Test
    fun cellularIsRefusedOnlyWhenNotAllowed() = runTest {
        assertFailsWith<TranscriptException.Network> { fetcher(cellularOnly = true).fetchDescriptionHTML(entry, allowsCellular = false) }
        assertThat(server.requestCount).isEqualTo(0)
        respond(200, """{"description":"ok"}""")
        assertThat(fetcher(cellularOnly = true).fetchDescriptionHTML(entry, allowsCellular = true)).isEqualTo("ok")
    }

    @Test
    fun urlsMatchTheSite() {
        val hindi = TranscriptCatalog.Entry("66265929d26d4da463e8850d", "ashtavakra-maha-geeta-01")
        assertThat(TranscriptCatalog.descriptionURL(hindi)).isEqualTo("https://oshoworld.com/api/server/audio/get-description/66265929d26d4da463e8850d")
        assertThat(TranscriptCatalog.pageURL(hindi)).isEqualTo("https://oshoworld.com/ashtavakra-maha-geeta-01")
    }
}
