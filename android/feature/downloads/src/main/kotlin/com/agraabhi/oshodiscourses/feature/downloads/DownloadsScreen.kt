package com.agraabhi.oshodiscourses.feature.downloads

import androidx.activity.compose.BackHandler
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation3.runtime.NavKey
import com.agraabhi.oshodiscourses.core.ui.LocalAppServices
import kotlinx.serialization.Serializable

/** The Downloads tab's root. */
@Serializable
data object DownloadsRoute : NavKey

/** Bookmarks list; one tap deep in Downloads on a phone. */
@Serializable
data object BookmarksRoute : NavKey

/** Listening Stats; reached from Downloads. */
@Serializable
data object ListeningStatsRoute : NavKey

/** Listening History, pushed from Listening Stats > Full Listening History. */
@Serializable
data object ListeningHistoryRoute : NavKey

/**
 * Downloads grouped by series, storage meter, stats and bookmarks (iOS `DownloadsView`).
 * [onAddBookmark] opens the player's Add Bookmark sheet for the current track; the context-menu
 * item is hidden while it is null.
 */
@Composable
fun DownloadsScreen(
    onOpenSeries: (seriesID: String) -> Unit,
    onOpenBookmarks: () -> Unit,
    onOpenListeningStats: () -> Unit,
    modifier: Modifier = Modifier,
    onAddBookmark: (() -> Unit)? = null,
) {
    val services = LocalAppServices.current
    val vm = viewModel {
        DownloadsViewModel(services.catalog, services.downloads, services.player, services.bookmarks, services.listeningStats)
    }
    val state by vm.state.collectAsStateWithLifecycle()
    DownloadsContent(
        state = state,
        coverURL = services.catalog::coverURL,
        modifier = modifier,
        actions = DownloadsActions(
            onQueryChange = vm::setQuery,
            onStartEditing = vm::startEditing,
            onExitEditing = vm::exitEditing,
            onToggleSelection = { vm.toggleSelection(it) },
            onDeleteSelection = vm::deleteSelection,
            onDeleteAll = vm::deleteAll,
            onDeleteSeries = { vm.deleteSeries(it) },
            onDelete = { vm.delete(it) },
            onPlay = { vm.play(it) },
            onPlayOrPause = { vm.playOrPause(it) },
            onCancel = { vm.cancel(it) },
            onDownload = { vm.download(it) },
            onForget = { vm.forget(it) },
            onUseMobileData = { vm.useMobileData() },
            onOpenSeries = onOpenSeries,
            onOpenBookmarks = onOpenBookmarks,
            onOpenListeningStats = onOpenListeningStats,
            onAddBookmark = onAddBookmark,
        ),
    )
}

/** iOS `BookmarksView`. [onBack] shows the glass back button when the page is pushed. */
@Composable
fun BookmarksScreen(modifier: Modifier = Modifier, onBack: (() -> Unit)? = null) {
    val services = LocalAppServices.current
    val vm = viewModel { BookmarksViewModel(services.bookmarks, services.downloads, services.player, services.catalog) }
    val state by vm.state.collectAsStateWithLifecycle()
    BookmarksContent(
        state = state,
        modifier = modifier,
        actions = BookmarksActions(
            onSelectFilter = vm::selectFilter,
            onPlay = { vm.play(it) },
            onDownload = { vm.download(it) },
            onDelete = { vm.delete(it) },
            onBack = onBack,
        ),
    )
}

/**
 * iOS `ListeningStatsView`. With [onOpenHistory] null, Full Listening History opens in place
 * and its back button returns here; pass it to push [ListeningHistoryRoute] instead.
 */
@Composable
fun ListeningStatsScreen(
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
    onOpenHistory: (() -> Unit)? = null,
) {
    val services = LocalAppServices.current
    val vm = viewModel { ListeningStatsViewModel(services.listeningStats, services.playbackState, services.catalog) }
    val state by vm.state.collectAsStateWithLifecycle()
    var showHistory by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(Unit) { vm.onAppear() }
    BackHandler(enabled = showHistory) { showHistory = false }
    if (showHistory) {
        ListeningHistoryContent(state, onBack = { showHistory = false }, modifier = modifier)
    } else {
        ListeningStatsContent(
            state = state,
            onOpenHistory = onOpenHistory ?: { showHistory = true },
            onBack = onBack,
            modifier = modifier,
        )
    }
}

/** iOS `ListeningHistoryDetailView`: the daily log and every played discourse. */
@Composable
fun ListeningHistoryScreen(modifier: Modifier = Modifier, onBack: (() -> Unit)? = null) {
    val services = LocalAppServices.current
    val vm = viewModel { ListeningStatsViewModel(services.listeningStats, services.playbackState, services.catalog) }
    val state by vm.state.collectAsStateWithLifecycle()
    ListeningHistoryContent(state, onBack = onBack, modifier = modifier)
}
