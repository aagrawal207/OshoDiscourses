package com.agraabhi.oshodiscourses.navigation

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.navigation3.rememberViewModelStoreNavEntryDecorator
import androidx.navigation3.runtime.NavEntry
import androidx.navigation3.runtime.NavKey
import androidx.navigation3.runtime.entryProvider
import androidx.navigation3.runtime.rememberDecoratedNavEntries
import androidx.navigation3.runtime.rememberSaveableStateHolderNavEntryDecorator
import androidx.navigation3.ui.NavDisplay
import com.agraabhi.oshodiscourses.core.ui.LocalAppServices
import com.agraabhi.oshodiscourses.core.ui.components.LocalHazeState
import com.agraabhi.oshodiscourses.core.ui.LocalMiniPlayerClearance
import com.agraabhi.oshodiscourses.core.ui.LocalTabBarClearance
import com.agraabhi.oshodiscourses.core.ui.components.OshoTabBar
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import com.agraabhi.oshodiscourses.core.ui.theme.ProvideElevatedSurfaces
import com.agraabhi.oshodiscourses.feature.downloads.BookmarksRoute
import com.agraabhi.oshodiscourses.feature.downloads.BookmarksScreen
import com.agraabhi.oshodiscourses.feature.downloads.DownloadsRoute
import com.agraabhi.oshodiscourses.feature.downloads.DownloadsScreen
import com.agraabhi.oshodiscourses.feature.downloads.ListeningStatsRoute
import com.agraabhi.oshodiscourses.feature.downloads.ListeningStatsScreen
import com.agraabhi.oshodiscourses.feature.home.HomeRoute
import com.agraabhi.oshodiscourses.feature.home.HomeScreen
import com.agraabhi.oshodiscourses.feature.library.LibraryRoute
import com.agraabhi.oshodiscourses.feature.library.LibraryScreen
import com.agraabhi.oshodiscourses.feature.player.DenoiseRoute
import com.agraabhi.oshodiscourses.feature.player.DenoiseScreen
import com.agraabhi.oshodiscourses.feature.player.MiniPlayer
import com.agraabhi.oshodiscourses.feature.player.PlayerScreen
import com.agraabhi.oshodiscourses.feature.series.SeriesRoute
import com.agraabhi.oshodiscourses.feature.series.SeriesScreen
import com.agraabhi.oshodiscourses.feature.settings.SettingsRoute
import com.agraabhi.oshodiscourses.feature.settings.SettingsScreen
import com.agraabhi.oshodiscourses.feature.transcript.TranscriptScreen
import dev.chrisbanes.haze.hazeSource
import dev.chrisbanes.haze.rememberHazeState

/** Gap between the tab bar and the mini-player, and the extra scroll room below it (iOS). */
private val MiniPlayerGap = 6.dp
private val MiniPlayerScrollExtra = 12.dp

/**
 * The phone tab shell (iOS `ContentView`, ui-style.md §5, §8). Pages draw edge to edge under
 * the glass tab bar so it can blur them; each tab keeps its own back stack.
 */
@Composable
fun AppShell(navigator: AppNavigator = rememberAppNavigator()) {
    val player by LocalAppServices.current.player.state.collectAsStateWithLifecycle()
    val density = LocalDensity.current
    var tabBarHeight by remember { mutableStateOf(0.dp) }
    var miniPlayerHeight by remember { mutableStateOf(64.dp) }
    val hazeState = rememberHazeState()

    // Every tab's entries stay decorated, so switching tabs keeps scroll state and view models.
    val entriesByTab = AppTab.entries.associateWith { tab ->
        key(tab) {
            rememberDecoratedNavEntries(
                backStack = navigator.stacks.getValue(tab),
                entryDecorators = listOf(
                    rememberSaveableStateHolderNavEntryDecorator(),
                    rememberViewModelStoreNavEntryDecorator(),
                ),
                entryProvider = tabEntryProvider(navigator),
            )
        }
    }

    // Android convention: back from another tab's root returns to Home before leaving.
    BackHandler(enabled = !navigator.isPlayerPresented && navigator.selectedTab != AppTab.HOME && navigator.currentStack.size == 1) {
        navigator.select(AppTab.HOME)
    }

    val miniPlayerClearance = if (player.hasTrack) miniPlayerHeight + MiniPlayerGap + MiniPlayerScrollExtra else 0.dp

    Box(Modifier.fillMaxSize().background(Osho.colors.systemBackground)) {
        CompositionLocalProvider(
            LocalTabBarClearance provides tabBarHeight,
            LocalMiniPlayerClearance provides miniPlayerClearance,
            LocalHazeState provides hazeState,
        ) {
            NavDisplay(
                entriesByTab.getValue(navigator.selectedTab),
                modifier = Modifier.fillMaxSize().hazeSource(hazeState),
                onBack = { navigator.pop() },
            )

            if (player.hasTrack) {
                MiniPlayer(
                    onOpenPlayer = navigator::showPlayer,
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .padding(bottom = tabBarHeight + MiniPlayerGap)
                        .onSizeChanged { miniPlayerHeight = with(density) { it.height.toDp() } },
                )
            }

            OshoTabBar(
                items = AppTab.entries.map { it.item },
                selectedIndex = navigator.selectedTab.ordinal,
                onSelect = { navigator.select(AppTab.entries[it]) },
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .onSizeChanged { tabBarHeight = with(density) { it.height.toDp() } },
            )
        }

        ModalLayer(visible = navigator.isPlayerPresented && player.hasTrack, onBack = navigator::closePlayer) {
            PlayerScreen(
                onDismiss = navigator::closePlayer,
                onOpenTranscript = navigator::showTranscript,
                onOpenSeries = navigator::openSeriesFromPlayer,
            )
        }

        val transcriptID = navigator.transcriptDiscourseID
        ModalLayer(visible = transcriptID != null, onBack = navigator::closeTranscript) {
            transcriptID?.let { TranscriptScreen(discourseID = it, onDismiss = navigator::closeTranscript) }
        }

        LaunchOverlay()
    }
}

private fun tabEntryProvider(navigator: AppNavigator): (NavKey) -> NavEntry<NavKey> = entryProvider {
    entry<HomeRoute> { HomeScreen(onOpenSeries = { navigator.push(SeriesRoute(it)) }) }
    entry<LibraryRoute> { LibraryScreen(onOpenSeries = { navigator.push(SeriesRoute(it)) }) }
    entry<DownloadsRoute> {
        DownloadsScreen(
            onOpenSeries = { navigator.push(SeriesRoute(it)) },
            onOpenBookmarks = { navigator.push(BookmarksRoute) },
            onOpenListeningStats = { navigator.push(ListeningStatsRoute) },
        )
    }
    entry<SettingsRoute> {
        SettingsScreen(
            onOpenDenoise = { navigator.push(DenoiseRoute) },
            onOpenListeningStats = { navigator.push(ListeningStatsRoute) },
        )
    }
    entry<SeriesRoute> { route -> SeriesScreen(seriesID = route.seriesID, onOpenPlayer = navigator::showPlayer) }
    entry<BookmarksRoute> { BookmarksScreen() }
    entry<ListeningStatsRoute> { ListeningStatsScreen() }
    entry<DenoiseRoute> { DenoiseScreen() }
}

/**
 * A full-height sheet over the shell (iOS `.sheet` large): slides up, elevated surfaces, and no
 * tab or mini-player clearance. A9 may replace it with a draggable sheet.
 */
@Composable
private fun ModalLayer(visible: Boolean, onBack: () -> Unit, content: @Composable () -> Unit) {
    AnimatedVisibility(
        visible = visible,
        enter = slideInVertically(tween(350)) { it },
        exit = slideOutVertically(tween(300)) { it } + fadeOut(tween(300)),
    ) {
        BackHandler(onBack = onBack)
        CompositionLocalProvider(
            LocalTabBarClearance provides Dp(0f),
            LocalMiniPlayerClearance provides Dp(0f),
            LocalHazeState provides null,
        ) {
            ProvideElevatedSurfaces {
                Box(Modifier.fillMaxSize().background(Osho.colors.systemBackground)) { content() }
            }
        }
    }
}
