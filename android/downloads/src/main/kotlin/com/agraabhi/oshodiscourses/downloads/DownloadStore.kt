package com.agraabhi.oshodiscourses.downloads

import android.util.Log
import com.agraabhi.oshodiscourses.core.model.CatalogDiscourse
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import java.io.File
import java.io.IOException
import java.net.URLEncoder

/**
 * iOS layout: `<filesDir>/Osho Discourses/<Series>/<Series> - #N.mp3`, `.download_manifest.json` and
 * `.download_history.json`. Android adds the persisted queue and resumable partial files.
 */
class DownloadStore(
    val filesDir: File,
    /** Partial transfers; outside [filesDir]'s audio folder so a half file is never played. */
    val partialDir: File,
) {
    private val manifestFile = File(filesDir, MANIFEST_FILE)
    private val historyFile = File(filesDir, HISTORY_FILE)
    private val queueFile = File(filesDir, QUEUE_FILE)

    val audioRoot: File get() = File(filesDir, ROOT_FOLDER)

    fun relativePath(discourse: CatalogDiscourse): String = relativePath(discourse.seriesName, discourse.number)

    fun file(relativePath: String): File = File(filesDir, relativePath)

    fun loadManifest(): Map<String, String> = read(manifestFile, manifestSerializer) ?: emptyMap()

    fun saveManifest(map: Map<String, String>) = write(manifestFile, json.encodeToString(manifestSerializer, map))

    fun loadHistory(): List<String> = read(historyFile, listSerializer) ?: emptyList()

    fun saveHistory(ids: Collection<String>) = write(historyFile, json.encodeToString(listSerializer, ids.toList()))

    fun loadQueue(): List<String> = read(queueFile, listSerializer) ?: emptyList()

    fun saveQueue(ids: List<String>) = write(queueFile, json.encodeToString(listSerializer, ids))

    fun partial(discourseID: String): PartialFile {
        val name = URLEncoder.encode(discourseID, Charsets.UTF_8.name())
        return PartialFile(File(partialDir, "$name.part"), File(partialDir, "$name.json"))
    }

    fun allPartials(): List<PartialFile> = partialDir.listFiles { file -> file.name.endsWith(".json") }
        .orEmpty()
        .map { meta -> PartialFile(File(partialDir, meta.name.removeSuffix(".json") + ".part"), meta) }

    private fun <T> read(file: File, serializer: kotlinx.serialization.KSerializer<T>): T? {
        if (!file.exists()) return null
        return try {
            json.decodeFromString(serializer, file.readText())
        } catch (e: Exception) {
            Log.w(TAG, "unreadable ${file.name}; starting empty", e)
            null
        }
    }

    /** Temp file then rename, so a crash or full disk mid-write never leaves a truncated file. */
    private fun write(file: File, text: String) {
        try {
            file.parentFile?.mkdirs()
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeText(text)
            if (!tmp.renameTo(file)) throw IOException("rename failed for ${file.name}")
        } catch (e: IOException) {
            Log.w(TAG, "failed to save ${file.name}", e)
        }
    }

    companion object {
        const val ROOT_FOLDER: String = "Osho Discourses"
        const val MANIFEST_FILE: String = ".download_manifest.json"
        const val HISTORY_FILE: String = ".download_history.json"
        const val QUEUE_FILE: String = ".download_queue.json"

        fun relativePath(seriesName: String, number: Int): String {
            val safeSeries = seriesName.replace("/", "-")
            return "$ROOT_FOLDER/$safeSeries/$safeSeries - #$number.mp3"
        }

        internal val json = Json { ignoreUnknownKeys = true }
        private val manifestSerializer = MapSerializer(String.serializer(), String.serializer())
        private val listSerializer = ListSerializer(String.serializer())
    }
}

/** What a resumed request must match: the same URL and, when the server gave one, the same validator. */
@Serializable
data class PartialMeta(
    val discourseID: String,
    val url: String,
    /** Strong ETag or Last-Modified, sent as `If-Range`. */
    val validator: String? = null,
    val totalBytes: Long? = null,
)

class PartialFile(val dataFile: File, val metaFile: File) {
    val size: Long get() = if (dataFile.exists()) dataFile.length() else 0

    fun readMeta(): PartialMeta? = if (!metaFile.exists()) {
        null
    } else {
        runCatching { DownloadStore.json.decodeFromString(PartialMeta.serializer(), metaFile.readText()) }.getOrNull()
    }

    fun writeMeta(meta: PartialMeta) {
        metaFile.parentFile?.mkdirs()
        metaFile.writeText(DownloadStore.json.encodeToString(PartialMeta.serializer(), meta))
    }

    /** True when every byte the server announced is on disk. */
    val isComplete: Boolean get() = readMeta()?.totalBytes?.let { it > 0 && size == it } == true

    fun delete() {
        dataFile.delete()
        metaFile.delete()
    }
}

private const val TAG = "Downloads"
