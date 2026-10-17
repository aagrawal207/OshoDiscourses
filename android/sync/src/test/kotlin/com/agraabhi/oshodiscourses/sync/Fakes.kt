package com.agraabhi.oshodiscourses.sync

import com.agraabhi.oshodiscourses.core.domain.bookmarks.Bookmark
import com.agraabhi.oshodiscourses.core.domain.sync.CloudSnapshot
import java.io.IOException

/** In-memory Drive app-data folder with hooks to simulate another device and failures. */
internal class FakeDriveApi : DriveApi {
    class StoredFile(val id: String, var content: String, var version: Long, val createdTime: String)

    val files = linkedMapOf<String, StoredFile>()
    val calls = mutableListOf<String>()
    val tokensSeen = mutableListOf<String>()
    val rejectedTokens = mutableSetOf<String>()

    /** Thrown by every call while set, as when offline. */
    var failure: Exception? = null

    /** Runs before the pre-write version check, to model another device writing at that moment. */
    var beforeGetFile: (() -> Unit)? = null

    private var nextID = 1
    private var createdCounter = 0

    fun seed(snapshot: CloudSnapshot, version: Long = 1): StoredFile = seedRaw(SnapshotJson.encode(snapshot), version)

    fun seedRaw(content: String, version: Long = 1): StoredFile {
        val file = StoredFile("file-${nextID++}", content, version, "2026-10-${10 + createdCounter++}T00:00:00Z")
        files[file.id] = file
        return file
    }

    /** Another device's write: bumps the version like Drive does. */
    fun writeFromOtherDevice(id: String, snapshot: CloudSnapshot) {
        val file = files.getValue(id)
        file.content = SnapshotJson.encode(snapshot)
        file.version += 1
    }

    fun only(): CloudSnapshot = SnapshotJson.decode(files.values.single().content)!!

    fun count(call: String): Int = calls.count { it == call }

    override suspend fun listFiles(token: String, name: String): List<DriveFile> {
        check(token, "list")
        return files.values.map { DriveFile(it.id, it.version, it.createdTime) }
    }

    override suspend fun getFile(token: String, id: String): DriveFile {
        beforeGetFile?.invoke()
        check(token, "get")
        val file = files[id] ?: throw DriveException.NotFound()
        return DriveFile(file.id, file.version, file.createdTime)
    }

    override suspend fun download(token: String, id: String): String {
        check(token, "download")
        return (files[id] ?: throw DriveException.NotFound()).content
    }

    override suspend fun create(token: String, name: String, content: String): DriveFile {
        check(token, "create")
        val file = seedRaw(content)
        return DriveFile(file.id, file.version, file.createdTime)
    }

    override suspend fun update(token: String, id: String, content: String): DriveFile {
        check(token, "update")
        val file = files[id] ?: throw DriveException.NotFound()
        file.content = content
        file.version += 1
        return DriveFile(file.id, file.version, file.createdTime)
    }

    override suspend fun delete(token: String, id: String) {
        check(token, "delete")
        files.remove(id) ?: throw DriveException.NotFound()
    }

    private fun check(token: String, call: String) {
        calls += call
        tokensSeen += token
        failure?.let { throw it }
        if (token in rejectedTokens) throw DriveException.Unauthorized()
    }
}

/** A tiny convergent store: max positions, union of completed and bookmarks, max per day. */
internal class FakeSnapshotStore(var local: CloudSnapshot = CloudSnapshot()) : SnapshotStore {
    var mergeCount = 0
        private set

    override suspend fun export(): CloudSnapshot = normalized(local)

    override suspend fun merge(incoming: CloudSnapshot): Boolean {
        mergeCount++
        val before = normalized(local)
        local = CloudSnapshot(
            positions = maxMerge(local.positions, incoming.positions),
            completed = local.completed + incoming.completed,
            bookmarks = local.bookmarks + incoming.bookmarks,
            dailyStats = maxMerge(local.dailyStats, incoming.dailyStats),
        )
        return normalized(local) != before
    }

    fun edit(transform: (CloudSnapshot) -> CloudSnapshot) {
        local = transform(local)
    }

    private fun maxMerge(a: Map<String, Double>, b: Map<String, Double>): Map<String, Double> =
        (a.keys + b.keys).associateWith { maxOf(a[it] ?: 0.0, b[it] ?: 0.0) }

    private fun normalized(s: CloudSnapshot) = CloudSnapshot(
        positions = s.positions.toSortedMap(),
        completed = s.completed.distinct().sorted(),
        bookmarks = s.bookmarks.distinctBy { it.id }.sortedBy { it.id },
        dailyStats = s.dailyStats.toSortedMap(),
    )
}

internal class FakeAuthorizer : DriveAuthorizer {
    /** What a silent request returns; [currentToken] is used when granted. */
    var silent: AuthOutcome? = null

    /** What the consent screen returns. */
    var interactive: AuthOutcome? = null
    var currentToken = "token-1"
    var accountName: String? = "listener@example.com"
    val cleared = mutableListOf<String>()
    val revoked = mutableListOf<String?>()
    var interactiveRequests = 0
        private set
    private var minted = 1

    override suspend fun authorize(interactive: Boolean): AuthOutcome {
        if (interactive) interactiveRequests++
        val chosen = if (interactive) this.interactive ?: silent else silent
        return chosen ?: AuthOutcome.Granted(currentToken, accountName)
    }

    override suspend fun clearToken(token: String) {
        cleared += token
        if (token == currentToken) currentToken = "token-${++minted}"
    }

    override suspend fun revoke(accountName: String?): Boolean {
        revoked += accountName
        return true
    }
}

internal class FakeScheduler : SyncScheduler {
    var periodic = 0
    var retries = 0
    var cancels = 0

    override fun schedulePeriodic() {
        periodic++
    }

    override fun scheduleRetry() {
        retries++
    }

    override fun cancelAll() {
        cancels++
    }
}

internal class InMemorySyncPreferences(
    override var enabled: Boolean = false,
    override var accountName: String? = null,
) : SyncPreferences

internal fun bookmark(id: String, discourseID: String = "d-1") = Bookmark(
    id = id,
    discourseID = discourseID,
    seriesName = "Series",
    title = "Title",
    timestamp = 42.0,
    createdAt = 1_760_000_000_000L,
)

internal val offline = IOException("Unable to resolve host www.googleapis.com")
