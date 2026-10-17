package com.agraabhi.oshodiscourses.sync

import com.agraabhi.oshodiscourses.core.domain.sync.CloudSnapshot
import kotlinx.coroutines.CancellationException

/**
 * Read-merge-write of the Drive snapshot. Drive v3 has no ETag precondition, so `version` is re-read
 * before writing; a write lost in that gap heals because its device pushes again next round.
 */
internal class DriveSyncEngine(
    private val api: DriveApi,
    private val store: SnapshotStore,
    private val maxAttempts: Int = MAX_ATTEMPTS,
) {
    private data class RemoteCopy(val id: String, val version: Long, val snapshot: CloudSnapshot)

    /** The last content seen on Drive, so an unchanged version skips the download. */
    private var cache: RemoteCopy? = null

    enum class Outcome { UP_TO_DATE, PUSHED }

    fun reset() {
        cache = null
    }

    /** Throws [DriveException.Conflict] when every attempt lost a race with another device. */
    suspend fun sync(token: String): Outcome {
        repeat(maxAttempts) {
            val outcome = try {
                attempt(token)
            } catch (_: DriveException.Conflict) {
                null
            } catch (_: DriveException.NotFound) {
                // The user deleted the app's hidden Drive data mid-round; list again and recreate.
                cache = null
                null
            }
            if (outcome != null) return outcome
        }
        throw DriveException.Conflict("Google Drive kept changing during sync")
    }

    private suspend fun attempt(token: String): Outcome? {
        val files = api.listFiles(token, DriveApi.SNAPSHOT_FILE_NAME)
            .sortedWith(compareBy<DriveFile> { it.createdTime ?: "" }.thenBy { it.id })
        if (files.isEmpty()) {
            val local = store.export()
            val created = api.create(token, DriveApi.SNAPSHOT_FILE_NAME, SnapshotJson.encode(local))
            cache = RemoteCopy(created.id, created.version, local)
            return Outcome.PUSHED
        }

        // Two devices connecting at once can each create a file; fold the extras into the oldest.
        val primary = files.first()
        val extras = files.drop(1)
        val remote = read(token, primary)
        remote?.let { store.merge(it) }
        for (extra in extras) {
            read(token, extra)?.let { store.merge(it) }
        }
        val merged = store.export()
        if (extras.isEmpty() && remote == merged) {
            cache = RemoteCopy(primary.id, primary.version, merged)
            return Outcome.UP_TO_DATE
        }

        if (api.getFile(token, primary.id).version != primary.version) return null
        val updated = api.update(token, primary.id, SnapshotJson.encode(merged))
        cache = RemoteCopy(updated.id, updated.version, merged)
        for (extra in extras) {
            try {
                api.delete(token, extra.id)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                // Left behind, it is merged and deleted again on the next round.
            }
        }
        return Outcome.PUSHED
    }

    /** Null when the file holds no readable snapshot, which forces an overwrite. */
    private suspend fun read(token: String, file: DriveFile): CloudSnapshot? {
        val cached = cache
        if (cached != null && cached.id == file.id && cached.version == file.version) return cached.snapshot
        return SnapshotJson.decode(api.download(token, file.id))
    }

    companion object {
        const val MAX_ATTEMPTS: Int = 3
    }
}
