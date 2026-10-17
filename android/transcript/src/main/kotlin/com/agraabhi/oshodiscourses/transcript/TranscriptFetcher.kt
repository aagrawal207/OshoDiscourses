package com.agraabhi.oshodiscourses.transcript

import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptException
import com.agraabhi.oshodiscourses.core.model.TranscriptCatalog
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.jsonObject
import okhttp3.Call
import okhttp3.Callback
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response

/**
 * Network side of transcripts (iOS `TranscriptFetcher`): the description HTML for a catalog entry,
 * first from oshoworld's JSON API and, if that fails, from the page's embedded `__NEXT_DATA__`.
 * [isCellularOnly] stands in for iOS `allowsCellularAccess`, which OkHttp has no request flag for.
 */
class TranscriptFetcher(
    client: OkHttpClient,
    private val isCellularOnly: () -> Boolean = { false },
    private val apiBase: String = TranscriptCatalog.API_BASE,
    private val siteBase: String = TranscriptCatalog.SITE_BASE,
) {
    // Same per-request idle timeout as iOS; newBuilder shares the app client's pool.
    private val client = client.newBuilder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build()

    /** The description HTML for [entry]. Tries the API, then the page. */
    suspend fun fetchDescriptionHTML(entry: TranscriptCatalog.Entry, allowsCellular: Boolean): String {
        if (!allowsCellular && isCellularOnly()) throw TranscriptException.Network(WAITING_FOR_WIFI)
        var lastError: TranscriptException = TranscriptException.NoDescription()
        try {
            val body = fetch(TranscriptCatalog.descriptionURL(entry, apiBase))
            descriptionFromAPIResponse(body)?.let { return it }
        } catch (e: TranscriptException) {
            lastError = e
        }
        val page = fetch(TranscriptCatalog.pageURL(entry, siteBase))
        return descriptionFromPageHTML(page) ?: throw lastError
    }

    private suspend fun fetch(url: String): String {
        // The site's own client sends this on every API call; it costs nothing to look like it.
        val request = Request.Builder().url(url).header("Content-type", "application/json").build()
        return try {
            client.newCall(request).await().use { response ->
                if (!response.isSuccessful) throw TranscriptException.BadStatus(response.code)
                withContext(Dispatchers.IO) { response.body.string() }
            }
        } catch (e: IOException) {
            throw TranscriptException.Network(e.message ?: e.javaClass.simpleName, e)
        }
    }

    private suspend fun Call.await(): Response = suspendCancellableCoroutine { continuation ->
        continuation.invokeOnCancellation { cancel() }
        enqueue(
            object : Callback {
                override fun onResponse(call: Call, response: Response) {
                    continuation.resume(response) { _, value, _ -> value.close() }
                }

                override fun onFailure(call: Call, e: IOException) {
                    continuation.resumeWithException(e)
                }
            },
        )
    }

    companion object {
        const val WAITING_FOR_WIFI: String = "Transcripts download on Wi-Fi only."

        private val json = Json { ignoreUnknownKeys = true }
        private const val NEXT_DATA_OPEN = "<script id=\"__NEXT_DATA__\" type=\"application/json\">"
        private val descriptionPath = listOf("props", "pageProps", "data", "pageData", "audioData", "description")

        /** `{"description": "<html>"}`; `{"error": true}`, a missing field or bad JSON yields null. */
        fun descriptionFromAPIResponse(body: String): String? {
            val obj = runCatching { json.parseToJsonElement(body).jsonObject }.getOrNull() ?: return null
            if ((obj["error"] as? JsonPrimitive)?.booleanOrNull == true) return null
            return (obj["description"] as? JsonPrimitive)?.takeIf { it.isString }?.content
        }

        /** Digs `props.pageProps.data.pageData.audioData.description` out of the Next.js page data. */
        fun descriptionFromPageHTML(html: String): String? {
            val start = html.indexOf(NEXT_DATA_OPEN).takeIf { it >= 0 }?.plus(NEXT_DATA_OPEN.length) ?: return null
            val end = html.indexOf("</script>", start).takeIf { it >= 0 } ?: return null
            var node = runCatching { json.parseToJsonElement(html.substring(start, end)) }.getOrNull() ?: return null
            for (key in descriptionPath) node = (node as? JsonObject)?.get(key) ?: return null
            return (node as? JsonPrimitive)?.takeIf { it.isString }?.content
        }
    }
}
