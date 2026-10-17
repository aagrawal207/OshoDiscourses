package com.agraabhi.oshodiscourses.core.data

import android.content.Context
import androidx.datastore.core.handlers.ReplaceFileCorruptionHandler
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.emptyPreferences
import androidx.datastore.preferences.preferencesDataStoreFile
import com.agraabhi.oshodiscourses.core.data.bookmarks.FileBookmarkRepository
import com.agraabhi.oshodiscourses.core.data.progress.FilePlaybackStateRepository
import com.agraabhi.oshodiscourses.core.data.settings.DataStoreSettingsRepository
import com.agraabhi.oshodiscourses.core.data.stats.FileListeningStatsRepository
import com.agraabhi.oshodiscourses.core.data.sync.CloudSnapshotCoordinator
import com.agraabhi.oshodiscourses.core.data.transcript.FileTranscriptStateRepository
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadManager
import kotlinx.coroutines.CoroutineScope

/**
 * The persistence repositories over `context.filesDir`. Create one per process: DataStore
 * rejects a second store over the same file. Construction reads every file synchronously.
 */
class DataRepositories(context: Context, scope: CoroutineScope) {
    private val directory = context.filesDir

    val settings: DataStoreSettingsRepository = DataStoreSettingsRepository(
        PreferenceDataStoreFactory.create(
            corruptionHandler = ReplaceFileCorruptionHandler { emptyPreferences() },
            scope = scope,
            produceFile = { context.applicationContext.preferencesDataStoreFile(DataStoreSettingsRepository.DATA_STORE_NAME) },
        ),
    )
    val playbackState: FilePlaybackStateRepository = FilePlaybackStateRepository(directory)
    val bookmarks: FileBookmarkRepository = FileBookmarkRepository(directory)
    val listeningStats: FileListeningStatsRepository = FileListeningStatsRepository(directory)
    val transcriptState: FileTranscriptStateRepository = FileTranscriptStateRepository(directory, scope)

    fun cloudSnapshotCoordinator(downloads: DownloadManager): CloudSnapshotCoordinator =
        CloudSnapshotCoordinator(playbackState, bookmarks, listeningStats, transcriptState, downloads)
}
