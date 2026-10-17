package com.agraabhi.oshodiscourses

import com.agraabhi.oshodiscourses.core.data.json.CloudSnapshotCodec
import com.agraabhi.oshodiscourses.core.data.sync.CloudSnapshotCoordinator
import com.agraabhi.oshodiscourses.core.domain.sync.CloudSnapshot
import com.agraabhi.oshodiscourses.sync.SnapshotCodec
import com.agraabhi.oshodiscourses.sync.SnapshotStore
import kotlinx.serialization.SerializationException

/** Drive sync reads and merges every repository through `:core:data`'s coordinator. */
class CoordinatorSnapshotStore(private val coordinator: CloudSnapshotCoordinator) : SnapshotStore {
    override suspend fun export(): CloudSnapshot = coordinator.export()

    override suspend fun merge(incoming: CloudSnapshot): Boolean = coordinator.merge(incoming).anyChanged
}

/** The Drive file in the iOS `CloudSnapshot` wire format (Swift dates, omitted nils), shared by both platforms. */
object IosSnapshotCodec : SnapshotCodec {
    override fun encode(snapshot: CloudSnapshot): String = CloudSnapshotCodec.encode(snapshot).decodeToString()

    override fun decode(text: String): CloudSnapshot? = try {
        CloudSnapshotCodec.decode(text.encodeToByteArray())
    } catch (_: SerializationException) {
        null
    } catch (_: IllegalArgumentException) {
        null
    }
}
