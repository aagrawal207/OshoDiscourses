package com.agraabhi.oshodiscourses.navigation

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.LibraryBooks
import androidx.compose.material.icons.rounded.DownloadForOffline
import androidx.compose.material.icons.rounded.Home
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.navigation3.runtime.NavKey
import com.agraabhi.oshodiscourses.core.ui.components.OshoTabItem
import com.agraabhi.oshodiscourses.feature.downloads.DownloadsRoute
import com.agraabhi.oshodiscourses.feature.home.HomeRoute
import com.agraabhi.oshodiscourses.feature.library.LibraryRoute
import com.agraabhi.oshodiscourses.feature.settings.SettingsRoute

/**
 * The phone tab bar, in iOS order (`AppTab`, ui-style.md §5.1). Icons are always filled, as
 * the iOS tab bar draws them. Bookmarks is a row inside Downloads on phones, not a tab.
 */
enum class AppTab(val title: String, val icon: ImageVector, val root: NavKey) {
    HOME("Home", Icons.Rounded.Home, HomeRoute),
    LIBRARY("Library", Icons.AutoMirrored.Rounded.LibraryBooks, LibraryRoute),
    DOWNLOADS("Downloads", Icons.Rounded.DownloadForOffline, DownloadsRoute),
    SETTINGS("Settings", Icons.Rounded.Settings, SettingsRoute),
    ;

    val item: OshoTabItem get() = OshoTabItem(title, icon)
}
