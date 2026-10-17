package com.agraabhi.oshodiscourses.sync

import android.app.Activity
import android.content.Context
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.ProcessLifecycleOwner
import com.agraabhi.oshodiscourses.core.domain.bookmarks.BookmarkRepository
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadManager
import com.agraabhi.oshodiscourses.core.domain.progress.PlaybackStateRepository
import com.agraabhi.oshodiscourses.core.domain.stats.ListeningStatsRepository
import com.agraabhi.oshodiscourses.core.domain.transcript.TranscriptStateRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.merge
import okhttp3.OkHttpClient

/** Builds the production [DriveSyncController]. Create it once, in `Application.onCreate`. */
object DriveSync {
    /**
     * [activityProvider] returns the resumed `ComponentActivity` that shows Google's consent screen.
     * [localChanges] emits after every local edit to synced data; see [localChanges].
     */
    fun create(
        context: Context,
        store: SnapshotStore,
        localChanges: Flow<Unit>,
        activityProvider: () -> Activity?,
        httpClient: OkHttpClient = OkHttpClient(),
        scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    ): DriveSyncController = DriveSyncController(
        store = store,
        api = OkHttpDriveApi(httpClient),
        authorizer = GoogleDriveAuthorizer(context, activityProvider),
        preferences = SharedSyncPreferences(context),
        scheduler = WorkManagerSyncScheduler(context),
        scope = scope,
        localChanges = localChanges,
        appVisibility = processVisibility(),
        clock = System::currentTimeMillis,
    )

    /**
     * Every synced slice's change stream, skipping the current value. iOS pushes on progress
     * auto-save and bookmark changes; stats, transcript state and download history ride along.
     */
    fun localChanges(
        playbackState: PlaybackStateRepository,
        bookmarks: BookmarkRepository,
        listeningStats: ListeningStatsRepository,
        transcriptState: TranscriptStateRepository,
        downloads: DownloadManager,
    ): Flow<Unit> = merge(
        playbackState.state.drop(1),
        bookmarks.bookmarks.drop(1),
        bookmarks.deletedBookmarkIDs.drop(1),
        listeningStats.stats.drop(1),
        transcriptState.states.drop(1),
        downloads.downloadHistory.drop(1),
    ).map { }

    /** True when the app comes to the foreground, false when it leaves. */
    private fun processVisibility(): Flow<Boolean> = callbackFlow {
        val lifecycle = ProcessLifecycleOwner.get().lifecycle
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START -> trySend(true)
                Lifecycle.Event.ON_STOP -> trySend(false)
                else -> Unit
            }
        }
        lifecycle.addObserver(observer)
        awaitClose { lifecycle.removeObserver(observer) }
    }.flowOn(Dispatchers.Main.immediate)
}
