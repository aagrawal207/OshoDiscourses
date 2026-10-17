package com.agraabhi.oshodiscourses.core.data.json

import com.agraabhi.oshodiscourses.core.domain.sync.CloudSnapshot
import kotlinx.serialization.SerializationException

/**
 * Bytes of a [CloudSnapshot] in the iOS `JSONEncoder` format: same keys, Swift-style dates and
 * omitted nil optionals. Use this rather than the domain type's default serializer, which
 * writes dates as epoch milliseconds.
 */
object CloudSnapshotCodec {
    fun encode(snapshot: CloudSnapshot): ByteArray =
        IosJson.encodeToString(CloudSnapshotJson.serializer(), CloudSnapshotJson.from(snapshot)).encodeToByteArray()

    /** Throws [SerializationException] or [IllegalArgumentException] for bytes that are not a snapshot. */
    fun decode(bytes: ByteArray): CloudSnapshot =
        IosJson.decodeFromString(CloudSnapshotJson.serializer(), bytes.decodeToString()).toDomain()
}
