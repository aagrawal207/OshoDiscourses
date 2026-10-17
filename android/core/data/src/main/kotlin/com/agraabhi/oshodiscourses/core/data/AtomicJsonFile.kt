package com.agraabhi.oshodiscourses.core.data

import com.agraabhi.oshodiscourses.core.data.json.IosJson
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerializationException
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/**
 * One JSON file written atomically (temp file, fsync, rename), so a crash mid-write cannot
 * leave a truncated file. Not thread-safe: each owner serialises its own writes.
 */
internal class AtomicJsonFile<T>(val file: File, private val serializer: KSerializer<T>) {

    /**
     * Null when the file is missing or unreadable. A file that exists but does not decode is
     * moved to `<name>.bak` first, so the next save cannot overwrite recoverable user data.
     */
    fun read(): T? {
        val text = try {
            if (!file.exists()) return null
            file.readText()
        } catch (_: IOException) {
            return null
        }
        return try {
            IosJson.decodeFromString(serializer, text)
        } catch (_: SerializationException) {
            preserveCorrupt()
            null
        } catch (_: IllegalArgumentException) {
            preserveCorrupt()
            null
        }
    }

    fun write(value: T) {
        val bytes = IosJson.encodeToString(serializer, value).encodeToByteArray()
        file.parentFile?.mkdirs()
        val temp = File(file.parentFile, "${file.name}.tmp")
        FileOutputStream(temp).use { out ->
            out.write(bytes)
            out.fd.sync()
        }
        Files.move(temp.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
    }

    /** The in-memory state stays authoritative when the disk is full; the next save retries. */
    fun writeQuietly(value: T): Boolean = try {
        write(value)
        true
    } catch (_: IOException) {
        false
    }

    private fun preserveCorrupt() {
        val backup = File(file.parentFile, "${file.name}.bak")
        try {
            Files.move(file.toPath(), backup.toPath(), StandardCopyOption.REPLACE_EXISTING)
        } catch (_: IOException) {
        }
    }
}
