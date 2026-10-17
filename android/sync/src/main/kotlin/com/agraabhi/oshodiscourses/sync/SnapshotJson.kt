package com.agraabhi.oshodiscourses.sync

import com.agraabhi.oshodiscourses.core.domain.sync.CloudSnapshot
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json

/** The Drive file's content: one [CloudSnapshot] as JSON, readable by newer and older app versions. */
internal object SnapshotJson {
    private val json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
        coerceInputValues = true
    }

    fun encode(snapshot: CloudSnapshot): String = json.encodeToString(CloudSnapshot.serializer(), snapshot)

    /** Null when the file is not a snapshot, so the caller overwrites it with a good one. */
    fun decode(text: String): CloudSnapshot? = try {
        json.decodeFromString(CloudSnapshot.serializer(), text)
    } catch (_: SerializationException) {
        null
    } catch (_: IllegalArgumentException) {
        null
    }
}
