package com.agraabhi.oshodiscourses.navigation

import androidx.compose.runtime.Composable
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.navigation3.runtime.NavBackStack
import androidx.navigation3.runtime.NavKey
import androidx.navigation3.runtime.rememberNavBackStack
import com.agraabhi.oshodiscourses.feature.series.SeriesRoute

/**
 * Per-window navigation (iOS `AppNavigation`): the selected tab, one back stack per tab that
 * survives tab switches, and the modal player and transcript.
 */
@Stable
class AppNavigator(
    val stacks: Map<AppTab, NavBackStack<NavKey>>,
    selectedTabState: MutableState<AppTab> = mutableStateOf(AppTab.HOME),
    playerPresentedState: MutableState<Boolean> = mutableStateOf(false),
    transcriptState: MutableState<String?> = mutableStateOf(null),
) {
    var selectedTab by selectedTabState
        private set
    var isPlayerPresented by playerPresentedState
        private set

    /** The transcript sheet shown over the player, if any. */
    var transcriptDiscourseID by transcriptState
        private set

    val currentStack: NavBackStack<NavKey> get() = stacks.getValue(selectedTab)

    /** Re-selecting the current tab pops it to its root, as a second tap on an iOS tab does. */
    fun select(tab: AppTab) {
        if (tab == selectedTab) popToRoot(tab) else selectedTab = tab
    }

    fun push(route: NavKey) {
        currentStack.add(route)
    }

    /** Pops the current tab; false at its root so the system can handle back. */
    fun pop(): Boolean {
        if (currentStack.size <= 1) return false
        currentStack.removeAt(currentStack.lastIndex)
        return true
    }

    fun showPlayer() {
        isPlayerPresented = true
    }

    fun closePlayer() {
        transcriptDiscourseID = null
        isPlayerPresented = false
    }

    fun showTranscript(discourseID: String) {
        transcriptDiscourseID = discourseID
    }

    fun closeTranscript() {
        transcriptDiscourseID = null
    }

    /** From the player's series title: close it, select Home, reset its stack, push the series. */
    fun openSeriesFromPlayer(seriesID: String) {
        closePlayer()
        selectedTab = AppTab.HOME
        popToRoot(AppTab.HOME)
        push(SeriesRoute(seriesID))
    }

    private fun popToRoot(tab: AppTab) {
        val stack = stacks.getValue(tab)
        while (stack.size > 1) stack.removeAt(stack.lastIndex)
    }
}

@Composable
fun rememberAppNavigator(): AppNavigator {
    val home = rememberNavBackStack(AppTab.HOME.root)
    val library = rememberNavBackStack(AppTab.LIBRARY.root)
    val downloads = rememberNavBackStack(AppTab.DOWNLOADS.root)
    val settings = rememberNavBackStack(AppTab.SETTINGS.root)
    val tab = rememberSaveable { mutableStateOf(AppTab.HOME) }
    val player = rememberSaveable { mutableStateOf(false) }
    val transcript = rememberSaveable { mutableStateOf<String?>(null) }
    return remember(home, library, downloads, settings) {
        AppNavigator(
            stacks = mapOf(AppTab.HOME to home, AppTab.LIBRARY to library, AppTab.DOWNLOADS to downloads, AppTab.SETTINGS to settings),
            selectedTabState = tab,
            playerPresentedState = player,
            transcriptState = transcript,
        )
    }
}
