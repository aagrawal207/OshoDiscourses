package com.agraabhi.oshodiscourses.core.testing

import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadManager
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadNetwork
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadState
import com.agraabhi.oshodiscourses.core.domain.downloads.WaitingReason
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update

/**
 * Downloads complete instantly unless [completeInstantly] is false, in which case they stay
 * [DownloadState.Queued] until [finish] or [setState]. Every file "weighs" [bytesPerFile].
 */
class FakeDownloadManager(
    downloaded: Set<String> = emptySet(),
    var completeInstantly: Boolean = true,
    private val bytesPerFile: Long = 25_000_000,
) : DownloadManager {
    override val states = MutableStateFlow(downloaded.associateWith<String, DownloadState> { DownloadState.Downloaded })
    override val downloadedIDs = MutableStateFlow(downloaded)
    override val downloadHistory = MutableStateFlow(downloaded)
    override val network = MutableStateFlow(DownloadNetwork.UNRESTRICTED)
    override val waitingReason = MutableStateFlow<WaitingReason?>(null)
    override val storageUsedBytes: StateFlow<Long> = MutableStateFlow(downloaded.size * bytesPerFile)
    var allowCellular: Boolean = false
        private set

    fun setState(discourseID: String, state: DownloadState) {
        states.update { if (state == DownloadState.NotDownloaded) it - discourseID else it + (discourseID to state) }
        val onDisk = state == DownloadState.Downloaded
        downloadedIDs.update { if (onDisk) it + discourseID else it - discourseID }
        if (onDisk) downloadHistory.update { it + discourseID }
        (storageUsedBytes as MutableStateFlow).value = downloadedIDs.value.size * bytesPerFile
    }

    fun finish(discourseID: String) = setState(discourseID, DownloadState.Downloaded)

    override fun localFileURI(discourseID: String): String? =
        if (discourseID in downloadedIDs.value) "file:///fake/$discourseID.mp3" else null

    override suspend fun enqueue(discourseID: String) {
        if (state(discourseID).isActive || state(discourseID) == DownloadState.Downloaded) return
        setState(discourseID, if (completeInstantly) DownloadState.Downloaded else DownloadState.Queued)
    }

    override suspend fun enqueueAll(discourseIDs: List<String>) = discourseIDs.forEach { enqueue(it) }

    override suspend fun cancel(discourseID: String) {
        if (state(discourseID).isActive) setState(discourseID, DownloadState.NotDownloaded)
    }

    override suspend fun delete(discourseID: String) = setState(discourseID, DownloadState.NotDownloaded)

    override suspend fun deleteDownloads(discourseIDs: List<String>) = discourseIDs.forEach { delete(it) }

    override suspend fun deleteSeries(seriesID: String) =
        deleteDownloads(downloadedIDs.value.filter { it.startsWith("$seriesID-") })

    override suspend fun deleteAll() = deleteDownloads(downloadedIDs.value.toList())

    override suspend fun useMobileData() {
        allowCellular = true
        waitingReason.value = null
    }

    override suspend fun downloadedSizes(): Map<String, Long> = downloadedIDs.value.associateWith { bytesPerFile }

    override fun inProgressIDs(): List<String> {
        val all = states.value
        return all.filterValues { it is DownloadState.Downloading }.keys.toList() +
            all.filterValues { it.isActive && it !is DownloadState.Downloading }.keys.toList()
    }

    override suspend fun mergeSyncedDownloadHistory(incoming: List<String>): Boolean {
        val before = downloadHistory.value
        downloadHistory.value = before + incoming
        return downloadHistory.value != before
    }

    override suspend fun forgetDownloadHistory(discourseIDs: List<String>) = downloadHistory.update { it - discourseIDs.toSet() }

    override fun syncedDownloadHistory(): List<String> = downloadHistory.value.toList()
}
