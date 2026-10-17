package com.agraabhi.oshodiscourses.sync

import com.agraabhi.oshodiscourses.core.domain.sync.CloudSnapshot
import kotlinx.coroutines.test.runTest
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okhttp3.OkHttpClient
import org.junit.After
import org.junit.Before
import org.junit.Test
import java.io.IOException
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class OkHttpDriveApiTest {
    private val server = MockWebServer()
    private lateinit var api: OkHttpDriveApi

    @Before
    fun setUp() {
        server.start()
        api = OkHttpDriveApi(OkHttpClient(), server.url("/"))
    }

    @After
    fun tearDown() {
        server.close()
    }

    private fun respond(code: Int = 200, body: String = "") {
        server.enqueue(MockResponse.Builder().code(code).body(body).build())
    }

    private fun file(id: String, version: Long) = """{"id":"$id","version":"$version","createdTime":"2026-10-17T00:00:00Z"}"""

    private fun RecordedRequest.bodyText(): String = body?.utf8() ?: ""

    @Test
    fun listSearchesOnlyTheAppDataFolderWithTheBearerToken() = runTest {
        respond(body = """{"files":[${file("abc", 12)}]}""")

        val files = api.listFiles("tok", DriveApi.SNAPSHOT_FILE_NAME)

        assertEquals(listOf(DriveFile("abc", 12, "2026-10-17T00:00:00Z")), files)
        val request = server.takeRequest()
        assertEquals("GET", request.method)
        assertEquals("/drive/v3/files", request.url.encodedPath)
        assertEquals("appDataFolder", request.url.queryParameter("spaces"))
        assertEquals("name = 'cloud.progress.v1.json' and trashed = false", request.url.queryParameter("q"))
        assertEquals("files(id,version,createdTime)", request.url.queryParameter("fields"))
        assertEquals("Bearer tok", request.headers["Authorization"])
    }

    @Test
    fun listWithNoFilesIsEmpty() = runTest {
        respond(body = """{"files":[]}""")
        assertEquals(emptyList(), api.listFiles("tok", DriveApi.SNAPSHOT_FILE_NAME))
    }

    @Test
    fun createUploadsMetadataAndContentIntoAppDataFolder() = runTest {
        respond(body = file("new", 1))

        val created = api.create("tok", DriveApi.SNAPSHOT_FILE_NAME, """{"completed":["d-1"]}""")

        assertEquals(DriveFile("new", 1, "2026-10-17T00:00:00Z"), created)
        val request = server.takeRequest()
        assertEquals("POST", request.method)
        assertEquals("/upload/drive/v3/files", request.url.encodedPath)
        assertEquals("multipart", request.url.queryParameter("uploadType"))
        assertTrue(request.headers["Content-Type"]!!.startsWith("multipart/related"))
        val body = request.bodyText()
        assertTrue(""""parents":["appDataFolder"]""" in body)
        assertTrue(""""name":"cloud.progress.v1.json"""" in body)
        assertTrue("""{"completed":["d-1"]}""" in body)
    }

    @Test
    fun updatePatchesTheMediaOfTheFile() = runTest {
        respond(body = file("abc", 13))

        val updated = api.update("tok", "abc", "{}")

        assertEquals(13, updated.version)
        val request = server.takeRequest()
        assertEquals("PATCH", request.method)
        assertEquals("/upload/drive/v3/files/abc", request.url.encodedPath)
        assertEquals("media", request.url.queryParameter("uploadType"))
        assertEquals("{}", request.bodyText())
    }

    @Test
    fun downloadGetAndDeleteHitTheFile() = runTest {
        respond(body = """{"completed":["x"]}""")
        respond(body = file("abc", 4))
        respond(code = 204)

        assertEquals("""{"completed":["x"]}""", api.download("tok", "abc"))
        assertEquals(4, api.getFile("tok", "abc").version)
        api.delete("tok", "abc")

        server.takeRequest().let {
            assertEquals("/drive/v3/files/abc", it.url.encodedPath)
            assertEquals("media", it.url.queryParameter("alt"))
        }
        assertEquals("id,version,createdTime", server.takeRequest().url.queryParameter("fields"))
        assertEquals("DELETE", server.takeRequest().method)
    }

    @Test
    fun httpErrorsMapToDriveExceptions() = runTest {
        respond(401, """{"error":{"code":401,"message":"Invalid Credentials","errors":[{"reason":"authError"}]}}""")
        assertFailsWith<DriveException.Unauthorized> { api.getFile("tok", "abc") }

        respond(403, """{"error":{"code":403,"message":"Slow down","errors":[{"reason":"userRateLimitExceeded"}]}}""")
        assertFailsWith<DriveException.RateLimited> { api.getFile("tok", "abc") }

        respond(403, """{"error":{"code":403,"message":"Drive API disabled","errors":[{"reason":"accessNotConfigured"}]}}""")
        val forbidden = assertFailsWith<DriveException.Forbidden> { api.getFile("tok", "abc") }
        assertEquals("accessNotConfigured", forbidden.reason)

        respond(404, """{"error":{"code":404,"message":"File not found"}}""")
        assertFailsWith<DriveException.NotFound> { api.getFile("tok", "abc") }

        respond(412, "")
        assertFailsWith<DriveException.Conflict> { api.update("tok", "abc", "{}") }

        respond(503, "unavailable")
        val server503 = assertFailsWith<DriveException.Server> { api.getFile("tok", "abc") }
        assertTrue(server503.transient)
    }

    @Test
    fun unreachableServerFailsWithIOException() = runTest {
        server.close()
        assertFailsWith<IOException> { api.listFiles("tok", DriveApi.SNAPSHOT_FILE_NAME) }
    }

    @Test
    fun engineRoundOverHttpReadsMergesChecksVersionAndWrites() = runTest {
        respond(body = """{"files":[${file("abc", 3)}]}""")
        respond(body = SnapshotJson.encode(CloudSnapshot(completed = listOf("remote"))))
        respond(body = file("abc", 3))
        respond(body = file("abc", 4))
        val store = FakeSnapshotStore(CloudSnapshot(completed = listOf("local")))

        val outcome = DriveSyncEngine(api, store).sync("tok")

        assertEquals(DriveSyncEngine.Outcome.PUSHED, outcome)
        val methods = List(4) { server.takeRequest() }
        assertEquals(listOf("GET", "GET", "GET", "PATCH"), methods.map { it.method })
        val pushed = SnapshotJson.decode(methods.last().bodyText())!!
        assertEquals(listOf("local", "remote"), pushed.completed)
    }
}
