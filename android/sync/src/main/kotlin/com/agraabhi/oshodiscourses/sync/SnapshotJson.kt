package com.agraabhi.oshodiscourses.sync

import com.agraabhi.oshodiscourses.core.domain.sync.CloudSnapshot
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json

/** The Drive file's text for one [CloudSnapshot]. */
interface SnapshotCodec {
    fun encode(snapshot: CloudSnapshot): String

    /** Null when the text is not a snapshot, so the caller overwrites it with a good one. */
    fun decode(text: String): CloudSnapshot?
}

/** The domain type's own JSON, readable by newer and older app versions; `:app` may supply the iOS shape instead. */
internal object SnapshotJson : SnapshotCodec {
    private val json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
        coerceInputValues = true
    }

    override fun encode(snapshot: CloudSnapshot): String = json.encodeToString(CloudSnapshot.serializer(), snapshot)

    override fun decode(text: String): CloudSnapshot? = try {
        json.decodeFromString(CloudSnapshot.serializer(), text)
    } catch (_: SerializationException) {
        null
    } catch (_: IllegalArgumentException) {
        null
    }
}
