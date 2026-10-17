package com.agraabhi.oshodiscourses.sync

import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.add
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Drive REST v3 over plain OkHttp. The Google API Java client would add megabytes and a second
 * HTTP stack for six calls.
 */
internal class OkHttpDriveApi(
    private val client: OkHttpClient,
    private val baseUrl: HttpUrl = DEFAULT_BASE_URL,
) : DriveApi {

    override suspend fun listFiles(token: String, name: String): List<DriveFile> {
        val url = baseUrl.newBuilder()
            .addPathSegments("drive/v3/files")
            .addQueryParameter("spaces", "appDataFolder")
            .addQueryParameter("q", "name = '$name' and trashed = false")
            .addQueryParameter("fields", "files($FILE_FIELDS)")
            .addQueryParameter("orderBy", "createdTime")
            .addQueryParameter("pageSize", "100")
            .build()
        val body = execute(Request.Builder().url(url).get(), token)
        val files = json.parseToJsonElement(body).jsonObject["files"] as? JsonArray ?: return emptyList()
        return files.map { parseFile(it.jsonObject) }
    }

    override suspend fun getFile(token: String, id: String): DriveFile {
        val url = fileUrl("drive/v3/files", id).addQueryParameter("fields", FILE_FIELDS).build()
        return parseFile(execute(Request.Builder().url(url).get(), token))
    }

    override suspend fun download(token: String, id: String): String {
        val url = fileUrl("drive/v3/files", id).addQueryParameter("alt", "media").build()
        return execute(Request.Builder().url(url).get(), token)
    }

    override suspend fun create(token: String, name: String, content: String): DriveFile {
        val metadata = buildJsonObject {
            put("name", name)
            put("mimeType", JSON_TYPE.toString())
            putJsonArray("parents") { add("appDataFolder") }
        }
        val body = MultipartBody.Builder()
            .setType(MULTIPART_RELATED)
            .addPart(metadata.toString().toRequestBody(JSON_TYPE))
            .addPart(content.toRequestBody(JSON_TYPE))
            .build()
        val url = baseUrl.newBuilder()
            .addPathSegments("upload/drive/v3/files")
            .addQueryParameter("uploadType", "multipart")
            .addQueryParameter("fields", FILE_FIELDS)
            .build()
        return parseFile(execute(Request.Builder().url(url).post(body), token))
    }

    override suspend fun update(token: String, id: String, content: String): DriveFile {
        val url = fileUrl("upload/drive/v3/files", id)
            .addQueryParameter("uploadType", "media")
            .addQueryParameter("fields", FILE_FIELDS)
            .build()
        return parseFile(execute(Request.Builder().url(url).patch(content.toRequestBody(JSON_TYPE)), token))
    }

    override suspend fun delete(token: String, id: String) {
        execute(Request.Builder().url(fileUrl("drive/v3/files", id).build()).delete(), token)
    }

    private fun fileUrl(path: String, id: String): HttpUrl.Builder =
        baseUrl.newBuilder().addPathSegments(path).addPathSegment(id)

    private fun parseFile(body: String): DriveFile = parseFile(json.parseToJsonElement(body).jsonObject)

    private fun parseFile(file: JsonObject): DriveFile {
        val id = file["id"]?.jsonPrimitive?.contentOrNull ?: throw DriveException.Server(200, "Drive file has no id")
        // Drive sends int64 fields as JSON strings.
        val version = file["version"]?.jsonPrimitive?.contentOrNull?.toLongOrNull() ?: 0L
        return DriveFile(id, version, file["createdTime"]?.jsonPrimitive?.contentOrNull)
    }

    private suspend fun execute(builder: Request.Builder, token: String): String {
        val request = builder.header("Authorization", "Bearer $token").build()
        val (code, body) = client.newCall(request).await()
        if (code in 200..299) return body
        throw errorFor(code, body)
    }

    private fun errorFor(code: Int, body: String): DriveException {
        val error = runCatching { json.parseToJsonElement(body).jsonObject["error"]?.jsonObject }.getOrNull()
        val message = error?.get("message")?.jsonPrimitive?.contentOrNull ?: "HTTP $code"
        val reason = runCatching {
            error?.get("errors")?.jsonArray?.firstOrNull()?.jsonObject?.get("reason")?.jsonPrimitive?.contentOrNull
        }.getOrNull()
        return when {
            code == 401 -> DriveException.Unauthorized(message)
            code == 403 && reason in RATE_LIMIT_REASONS -> DriveException.RateLimited(message)
            code == 403 && reason in AUTH_REASONS -> DriveException.Unauthorized(message)
            code == 403 -> DriveException.Forbidden(reason, message)
            code == 404 -> DriveException.NotFound(message)
            code == 409 || code == 412 -> DriveException.Conflict(message)
            code == 429 -> DriveException.RateLimited(message)
            code >= 500 -> DriveException.Server(code, message)
            else -> DriveException.Http(code, message)
        }
    }

    companion object {
        val DEFAULT_BASE_URL: HttpUrl = "https://www.googleapis.com/".toHttpUrl()
        private const val FILE_FIELDS = "id,version,createdTime"
        private val JSON_TYPE = "application/json; charset=UTF-8".toMediaType()
        private val MULTIPART_RELATED = "multipart/related".toMediaType()
        private val RATE_LIMIT_REASONS = setOf("rateLimitExceeded", "userRateLimitExceeded")
        private val AUTH_REASONS = setOf("authError", "insufficientPermissions", "insufficientScopes")
        private val json = Json { ignoreUnknownKeys = true }
    }
}

/** Reads the body on OkHttp's thread, so callers never block on network I/O. */
private suspend fun Call.await(): Pair<Int, String> = suspendCancellableCoroutine { continuation ->
    continuation.invokeOnCancellation { cancel() }
    enqueue(
        object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                continuation.resumeWithException(e)
            }

            override fun onResponse(call: Call, response: Response) {
                val result = try {
                    response.use { it.code to it.body.string() }
                } catch (e: IOException) {
                    continuation.resumeWithException(e)
                    return
                }
                continuation.resume(result)
            }
        },
    )
}
