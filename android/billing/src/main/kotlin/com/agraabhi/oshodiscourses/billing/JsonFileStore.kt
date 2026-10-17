package com.agraabhi.oshodiscourses.billing

import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json

/**
 * A small JSON file read once at construction (like iOS `UserDefaults`) and replaced atomically
 * on each write, so state recorded before an acknowledgement survives a crash.
 */
internal class JsonFileStore<T>(
    private val file: File,
    private val serializer: KSerializer<T>,
    private val default: T,
    private val io: CoroutineDispatcher = Dispatchers.IO,
) {
    private val mutex = Mutex()

    fun read(): T = try {
        if (file.exists()) json.decodeFromString(serializer, file.readText()) else default
    } catch (_: IOException) {
        default
    } catch (_: SerializationException) {
        default
    } catch (_: IllegalArgumentException) {
        default
    }

    /** Takes the snapshot inside the lock, so overlapping writers never persist an older value last. */
    suspend fun write(snapshot: () -> T) = mutex.withLock {
        val text = json.encodeToString(serializer, snapshot())
        withContext(io) {
            file.parentFile?.mkdirs()
            val temp = File(file.parentFile, "${file.name}.tmp")
            temp.writeText(text)
            Files.move(temp.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
        }
    }

    private companion object {
        val json = Json {
            ignoreUnknownKeys = true
            encodeDefaults = true
        }
    }
}
