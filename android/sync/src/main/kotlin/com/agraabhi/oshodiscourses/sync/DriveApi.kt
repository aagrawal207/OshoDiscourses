package com.agraabhi.oshodiscourses.sync

import com.agraabhi.oshodiscourses.core.domain.sync.CloudSnapshot

/** Drive v3 calls in the hidden `appDataFolder`. I/O fails with IOException, HTTP with [DriveException]. */
internal interface DriveApi {
    /** Every non-trashed file called [name] in `appDataFolder`. */
    suspend fun listFiles(token: String, name: String): List<DriveFile>

    suspend fun getFile(token: String, id: String): DriveFile

    suspend fun download(token: String, id: String): String

    suspend fun create(token: String, name: String, content: String): DriveFile

    suspend fun update(token: String, id: String, content: String): DriveFile

    suspend fun delete(token: String, id: String)

    companion object {
        const val SNAPSHOT_FILE_NAME: String = CloudSnapshot.SNAPSHOT_KEY + ".json"
        const val APP_DATA_SCOPE: String = "https://www.googleapis.com/auth/drive.appdata"
    }
}

/** [version] grows on every change to the file, so an unchanged version means unchanged content. */
internal data class DriveFile(val id: String, val version: Long, val createdTime: String? = null)

internal sealed class DriveException(message: String, val transient: Boolean) : Exception(message) {
    /** The token expired or lost the app-data scope. */
    class Unauthorized(message: String = "Unauthorized") : DriveException(message, transient = false)

    class NotFound(message: String = "Not found") : DriveException(message, transient = false)

    /** Another device wrote between our read and our write. */
    class Conflict(message: String = "Conflict") : DriveException(message, transient = true)

    class RateLimited(message: String = "Rate limited") : DriveException(message, transient = true)

    class Server(val code: Int, message: String) : DriveException(message, transient = true)

    /** For example the Drive API is not enabled for the Cloud project. Retrying will not help. */
    class Forbidden(val reason: String?, message: String) : DriveException(message, transient = false)

    class Http(val code: Int, message: String) : DriveException(message, transient = false)
}
