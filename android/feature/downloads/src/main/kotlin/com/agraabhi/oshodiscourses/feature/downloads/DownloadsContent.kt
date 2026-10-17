package com.agraabhi.oshodiscourses.feature.downloads

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ArrowCircleDown
import androidx.compose.material.icons.outlined.BookmarkBorder
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Pause
import androidx.compose.material.icons.outlined.PlayArrow
import androidx.compose.material.icons.rounded.BarChart
import androidx.compose.material.icons.rounded.Bookmark
import androidx.compose.material.icons.rounded.Cancel
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.MoreHoriz
import androidx.compose.material.icons.rounded.PauseCircle
import androidx.compose.material.icons.rounded.PlayCircle
import androidx.compose.material.icons.rounded.RadioButtonUnchecked
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.agraabhi.oshodiscourses.core.domain.downloads.WaitingReason
import com.agraabhi.oshodiscourses.core.ui.bottomClearance
import com.agraabhi.oshodiscourses.core.ui.components.ActionSheet
import com.agraabhi.oshodiscourses.core.ui.components.CardRow
import com.agraabhi.oshodiscourses.core.ui.components.EmptyState
import com.agraabhi.oshodiscourses.core.ui.components.GlassIconButton
import com.agraabhi.oshodiscourses.core.ui.components.GlassTextButton
import com.agraabhi.oshodiscourses.core.ui.components.Grouped
import com.agraabhi.oshodiscourses.core.ui.components.GroupedPage
import com.agraabhi.oshodiscourses.core.ui.components.ListSectionFooter
import com.agraabhi.oshodiscourses.core.ui.components.MenuAction
import com.agraabhi.oshodiscourses.core.ui.components.OshoMenu
import com.agraabhi.oshodiscourses.core.ui.components.SearchField
import com.agraabhi.oshodiscourses.core.ui.components.SeriesThumbnail
import com.agraabhi.oshodiscourses.core.ui.components.SheetAction
import com.agraabhi.oshodiscourses.core.ui.components.SmallSpinner
import com.agraabhi.oshodiscourses.core.ui.components.glass
import com.agraabhi.oshodiscourses.core.ui.components.rowContentPadding
import com.agraabhi.oshodiscourses.core.ui.components.sectionFooter
import com.agraabhi.oshodiscourses.core.ui.components.sectionGap
import com.agraabhi.oshodiscourses.core.ui.components.sectionHeader
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import com.agraabhi.oshodiscourses.core.ui.theme.monospacedDigits

/** Callbacks the Downloads tab raises; the view model handles everything else. */
internal class DownloadsActions(
    val onQueryChange: (String) -> Unit = {},
    val onStartEditing: () -> Unit = {},
    val onExitEditing: () -> Unit = {},
    val onToggleSelection: (String) -> Unit = {},
    val onDeleteSelection: () -> Unit = {},
    val onDeleteAll: () -> Unit = {},
    val onDeleteSeries: (String) -> Unit = {},
    val onDelete: (String) -> Unit = {},
    val onPlay: (String) -> Unit = {},
    val onPlayOrPause: (String) -> Unit = {},
    val onCancel: (String) -> Unit = {},
    val onDownload: (String) -> Unit = {},
    val onForget: (String) -> Unit = {},
    val onUseMobileData: () -> Unit = {},
    val onOpenSeries: (String) -> Unit = {},
    val onOpenBookmarks: () -> Unit = {},
    val onOpenListeningStats: () -> Unit = {},
    val onAddBookmark: (() -> Unit)? = null,
)

@Composable
internal fun DownloadsContent(
    state: DownloadsUiState,
    actions: DownloadsActions,
    coverURL: (String) -> String?,
    modifier: Modifier = Modifier,
) {
    var confirmDeleteAll by remember { mutableStateOf(false) }
    var seriesPendingDelete by remember { mutableStateOf<Pair<String, String>?>(null) }
    var toolbarMenu by remember { mutableStateOf(false) }

    GroupedPage(
        title = "Downloads",
        largeTitle = true,
        background = Osho.colors.systemGroupedBackground,
        modifier = modifier,
        extraBottomPadding = if (state.isEditing) 56.dp else 0.dp,
        actions = {
            if (state.groups.isNotEmpty()) {
                if (state.isEditing) {
                    GlassTextButton("Done", actions.onExitEditing, hazeState = null)
                } else {
                    Box {
                        GlassIconButton(Icons.Rounded.MoreHoriz, "More options", { toolbarMenu = true }, tint = Osho.colors.accent, iconSize = 22.dp, hazeState = null)
                        OshoMenu(
                            expanded = toolbarMenu,
                            onDismiss = { toolbarMenu = false },
                            actions = listOf(
                                MenuAction("Select", Icons.Outlined.CheckCircle, onClick = actions.onStartEditing),
                                MenuAction("Delete All", Icons.Outlined.Delete, destructive = true) { confirmDeleteAll = true },
                            ),
                        )
                    }
                }
            }
        },
        overlay = {
            if (state.isEditing) {
                SelectionBar(
                    count = state.selection.size,
                    onDelete = actions.onDeleteSelection,
                    modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = bottomClearance),
                )
            }
        },
    ) {
        item(key = "search", contentType = "search") {
            SearchField(state.query, actions.onQueryChange, "Search downloads", Modifier.padding(bottom = 4.dp))
        }
        if (state.showInProgress) inProgressSection(state, actions)
        downloadedSections(
            state = state,
            actions = actions,
            first = !state.showInProgress,
            coverURL = coverURL,
            onDeleteSeries = { id, name -> seriesPendingDelete = id to name },
        )
        if (state.showPreviouslyDownloaded) previouslyDownloadedSection(state, actions)
        if (!state.isEditing) activitySection(state, actions)
    }

    if (confirmDeleteAll) {
        ActionSheet(
            title = "Delete all ${state.downloadedCount} downloaded discourses?",
            message = "This removes the audio files from this device. Your bookmarks and listening history are kept.",
            actions = listOf(SheetAction("Delete All", destructive = true, onClick = actions.onDeleteAll)),
            onDismiss = { confirmDeleteAll = false },
        )
    }
    seriesPendingDelete?.let { (id, name) ->
        ActionSheet(
            title = "Delete all downloads in $name?",
            message = null,
            actions = listOf(SheetAction("Delete Series Downloads", destructive = true) { actions.onDeleteSeries(id) }),
            onDismiss = { seriesPendingDelete = null },
        )
    }
}

private fun LazyListScope.inProgressSection(state: DownloadsUiState, actions: DownloadsActions) {
    sectionHeader("downloading.header", "Downloading", first = true)
    val waiting = state.waitingReason
    val rowCount = state.inProgress.size + if (waiting != null) 1 else 0
    if (waiting != null) {
        item(key = "downloading.notice", contentType = "notice") {
            CardRow(isFirst = true, isLast = rowCount == 1) {
                DownloadWaitingNotice(
                    waiting,
                    actions.onUseMobileData,
                    Modifier.padding(horizontal = Grouped.rowPadding, vertical = 12.dp),
                )
            }
        }
    }
    itemsIndexed(state.inProgress, key = { _, item -> "downloading.${item.discourse.id}" }, contentType = { _, _ -> "inProgress" }) { index, item ->
        val position = index + if (waiting != null) 1 else 0
        CardRow(isFirst = position == 0, isLast = position == rowCount - 1) {
            InProgressRow(item, waiting, onCancel = { actions.onCancel(item.discourse.id) })
        }
    }
    sectionFooter("downloading.footer", "Downloads run one at a time. Tap to cancel.")
}

@Composable
private fun InProgressRow(item: InProgressItem, waiting: WaitingReason?, onCancel: () -> Unit) {
    val colors = Osho.colors
    val percent = (item.progress * 100).toInt()
    val status = waiting?.rowLabel ?: "$percent%"
    Row(
        Modifier.fillMaxWidth().rowContentPadding(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(item.discourse.seriesName, style = Osho.typography.body, color = colors.label, maxLines = 2)
            Text("Discourse ${item.discourse.number}", style = Osho.typography.caption2, color = colors.secondaryLabel)
            if (item.isQueued) {
                Text("Queued", style = Osho.typography.caption2, color = colors.secondaryLabel)
            } else {
                LinearProgressIndicator(
                    progress = { item.progress.toFloat() },
                    color = colors.accent,
                    trackColor = colors.systemFill,
                    gapSize = 0.dp,
                    drawStopIndicator = {},
                    modifier = Modifier.fillMaxWidth().height(4.dp).clip(CircleShape),
                )
                Text(status, style = Osho.typography.caption2.monospacedDigits(), color = colors.secondaryLabel)
            }
        }
        Icon(
            Icons.Rounded.Cancel,
            contentDescription = null,
            tint = colors.secondaryLabel,
            modifier = Modifier
                .size(44.dp)
                .clip(CircleShape)
                .clickable(role = Role.Button, onClick = onCancel)
                .semantics {
                    contentDescription = "Cancel download"
                    stateDescription = if (item.isQueued) "Queued" else waiting?.rowLabel ?: "$percent percent"
                }
                .padding(10.dp),
        )
    }
}

private fun LazyListScope.downloadedSections(
    state: DownloadsUiState,
    actions: DownloadsActions,
    first: Boolean,
    coverURL: (String) -> String?,
    onDeleteSeries: (String, String) -> Unit,
) {
    if (state.groups.isEmpty()) {
        sectionHeader("downloads.header", "Downloads", first = first)
        item(key = "downloads.empty", contentType = "empty") {
            if (state.isSearching) {
                EmptyState(Icons.Rounded.Search, "No Results", "No downloads match \"${state.query}\".")
            } else {
                EmptyState(Icons.Outlined.ArrowCircleDown, "No Downloads", "Downloaded discourses will appear here.")
            }
        }
        return
    }
    state.groups.forEachIndexed { groupIndex, group ->
        item(key = "series.${group.series.id}", contentType = "seriesHeader") {
            SeriesHeader(
                group = group,
                first = first && groupIndex == 0,
                coverURL = coverURL(group.series.id),
                showMenu = !state.isEditing,
                onOpen = { actions.onOpenSeries(group.series.id) },
                onDeleteSeries = { onDeleteSeries(group.series.id, group.series.name) },
            )
        }
        itemsIndexed(group.items, key = { _, item -> "downloaded.${item.discourse.id}" }, contentType = { _, _ -> "downloaded" }) { index, item ->
            val id = item.discourse.id
            CardRow(
                isFirst = index == 0,
                isLast = index == group.items.lastIndex,
                dividerStart = if (state.isEditing) 88.dp else 52.dp,
                onSwipeDelete = if (state.isEditing) null else { -> actions.onDelete(id) },
            ) {
                DownloadedRow(
                    item = item,
                    isCurrent = state.currentTrackId == id,
                    isPlaying = state.isPlayingNow(id),
                    isEditing = state.isEditing,
                    isSelected = id in state.selection,
                    actions = actions,
                )
            }
        }
        if (groupIndex == state.groups.lastIndex) {
            item(key = "downloads.footer", contentType = "footer") { DownloadsFooter(state) }
        }
    }
}

@Composable
private fun SeriesHeader(
    group: DownloadedGroup,
    first: Boolean,
    coverURL: String?,
    showMenu: Boolean,
    onOpen: () -> Unit,
    onDeleteSeries: () -> Unit,
) {
    val colors = Osho.colors
    var menu by remember { mutableStateOf(false) }
    Row(
        Modifier
            .fillMaxWidth()
            .padding(start = Grouped.sideInset + Grouped.rowPadding, end = Grouped.sideInset + 4.dp)
            .padding(top = if (first) 8.dp else 20.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(
            Modifier
                .weight(1f)
                .clickable(role = Role.Button, onClickLabel = "Opens the series", onClick = onOpen)
                .padding(vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            SeriesThumbnail(group.series.name, 32.dp, coverURL = coverURL)
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(group.series.name, style = Osho.typography.subheadline, fontWeight = FontWeight.SemiBold, color = colors.label)
                Text(group.subtitle, style = Osho.typography.caption2, color = colors.secondaryLabel)
            }
        }
        if (showMenu) {
            Box {
                Icon(
                    Icons.Rounded.MoreHoriz,
                    contentDescription = "Series options",
                    tint = colors.accentSecondary,
                    modifier = Modifier
                        .size(44.dp)
                        .clip(CircleShape)
                        .clickable(role = Role.Button) { menu = true }
                        .padding(12.dp),
                )
                OshoMenu(
                    expanded = menu,
                    onDismiss = { menu = false },
                    actions = listOf(MenuAction("Delete All in Series", Icons.Outlined.Delete, destructive = true, onClick = onDeleteSeries)),
                )
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun DownloadedRow(
    item: DownloadedItem,
    isCurrent: Boolean,
    isPlaying: Boolean,
    isEditing: Boolean,
    isSelected: Boolean,
    actions: DownloadsActions,
) {
    val colors = Osho.colors
    val id = item.discourse.id
    val haptics = LocalHapticFeedback.current
    var menu by remember { mutableStateOf(false) }
    Box {
        Row(
            Modifier
                .fillMaxWidth()
                .combinedClickable(
                    role = Role.Button,
                    onClickLabel = if (isEditing) null else "Plays this discourse",
                    onLongClick = if (isEditing) {
                        null
                    } else {
                        {
                            haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                            menu = true
                        }
                    },
                    onClick = { if (isEditing) actions.onToggleSelection(id) else actions.onPlay(id) },
                )
                .semantics(mergeDescendants = true) {
                    if (isEditing) stateDescription = if (isSelected) "Selected" else "Not selected"
                }
                .rowContentPadding(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (isEditing) {
                Icon(
                    if (isSelected) Icons.Rounded.CheckCircle else Icons.Rounded.RadioButtonUnchecked,
                    contentDescription = null,
                    tint = if (isSelected) colors.accent else colors.tertiaryLabel,
                    modifier = Modifier.size(24.dp),
                )
            }
            Text(
                "${item.discourse.number}",
                style = Osho.typography.caption,
                color = colors.secondaryLabel,
                maxLines = 1,
                modifier = Modifier.widthIn(min = 24.dp).clearAndSetSemantics {},
            )
            Text(
                "Discourse ${item.discourse.number}",
                style = Osho.typography.body,
                color = if (isCurrent) colors.accent else colors.label,
                maxLines = 1,
                modifier = Modifier.weight(1f),
            )
            item.sizeText?.let { Text(it, style = Osho.typography.caption2.monospacedDigits(), color = colors.secondaryLabel, maxLines = 1) }
            if (!isEditing) {
                Icon(
                    if (isPlaying) Icons.Rounded.PauseCircle else Icons.Rounded.PlayCircle,
                    contentDescription = if (isPlaying) "Pause" else "Play",
                    tint = colors.accent,
                    modifier = Modifier
                        .size(28.dp)
                        .clip(CircleShape)
                        .clickable(role = Role.Button) { actions.onPlayOrPause(id) },
                )
            }
        }
        OshoMenu(
            expanded = menu,
            onDismiss = { menu = false },
            actions = buildList {
                add(
                    MenuAction(if (isPlaying) "Pause" else "Play", if (isPlaying) Icons.Outlined.Pause else Icons.Outlined.PlayArrow) {
                        actions.onPlayOrPause(id)
                    },
                )
                val addBookmark = actions.onAddBookmark
                if (isCurrent && addBookmark != null) add(MenuAction("Add Bookmark…", Icons.Outlined.BookmarkBorder, onClick = addBookmark))
                add(MenuAction("Remove Download", Icons.Outlined.Delete, destructive = true, dividerBefore = true) { actions.onDelete(id) })
            },
        )
    }
}

@Composable
private fun DownloadsFooter(state: DownloadsUiState) {
    val showHint = !state.isEditing
    if (!showHint && !state.showUsage) return
    Column(Modifier.fillMaxWidth()) {
        if (showHint) {
            ListSectionFooter("Swipe a discourse left to delete, or use a series' ••• menu to clear a whole series or select several.")
        }
        if (showHint && state.showUsage) {
            Box(
                Modifier
                    .padding(horizontal = Grouped.sideInset + Grouped.rowPadding)
                    .padding(top = 8.dp)
                    .fillMaxWidth()
                    .height(1.dp)
                    .background(Osho.colors.separator),
            )
        }
        if (state.showUsage) {
            ListSectionFooter("${Formats.bytes(state.totalBytes)} used on this device")
        }
    }
}

private fun LazyListScope.previouslyDownloadedSection(state: DownloadsUiState, actions: DownloadsActions) {
    sectionHeader("previous.header", "Previously Downloaded")
    itemsIndexed(state.previouslyDownloaded, key = { _, item -> "previous.${item.discourse.id}" }, contentType = { _, _ -> "previous" }) { index, item ->
        CardRow(
            isFirst = index == 0,
            isLast = index == state.previouslyDownloaded.lastIndex,
            onSwipeDelete = { actions.onForget(item.discourse.id) },
        ) {
            RedownloadRow(item, onDownload = { actions.onDownload(item.discourse.id) }, onCancel = { actions.onCancel(item.discourse.id) })
        }
    }
    sectionFooter("previous.footer", "Removed from this device. Tap to download again, or swipe to remove from this list.")
}

@Composable
private fun RedownloadRow(item: RedownloadItem, onDownload: () -> Unit, onCancel: () -> Unit) {
    val colors = Osho.colors
    Row(
        Modifier.fillMaxWidth().rowContentPadding(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(item.discourse.seriesName, style = Osho.typography.body, color = colors.label, maxLines = 2)
            Text("Discourse ${item.discourse.number}", style = Osho.typography.caption2, color = colors.secondaryLabel)
        }
        if (item.isDownloading) {
            Box(
                Modifier
                    .size(44.dp)
                    .clip(CircleShape)
                    .clickable(role = Role.Button, onClick = onCancel)
                    .semantics {
                        contentDescription = "Cancel download"
                        stateDescription = if (item.isQueued) "Queued" else "${(item.progress * 100).toInt()} percent"
                    },
                contentAlignment = Alignment.Center,
            ) {
                if (item.isQueued) {
                    SmallSpinner(size = 18.dp)
                } else {
                    CircularProgressIndicator(
                        progress = { item.progress.toFloat() },
                        color = colors.accent,
                        trackColor = colors.label.copy(alpha = 0.15f),
                        strokeWidth = 2.5.dp,
                        gapSize = 0.dp,
                        modifier = Modifier.size(26.dp),
                    )
                }
            }
        } else {
            Text(
                "GET ${item.estimatedSize}",
                style = Osho.typography.caption,
                fontWeight = FontWeight.Bold,
                color = colors.accent,
                maxLines = 1,
                modifier = Modifier
                    .clip(CircleShape)
                    .background(colors.accent.copy(alpha = 0.15f))
                    .clickable(role = Role.Button, onClick = onDownload)
                    .padding(horizontal = 10.dp, vertical = 6.dp),
            )
        }
    }
}

private fun LazyListScope.activitySection(state: DownloadsUiState, actions: DownloadsActions) {
    sectionGap("activity.gap", 32.dp)
    item(key = "activity.stats", contentType = "activity") {
        CardRow(isFirst = true, isLast = false, dividerStart = 52.dp) {
            ActivityRow(
                icon = Icons.Rounded.BarChart,
                tint = Osho.colors.accent,
                title = "Listening Stats",
                subtitle = state.statsSubtitle,
                onClick = actions.onOpenListeningStats,
            )
        }
    }
    item(key = "activity.bookmarks", contentType = "activity") {
        CardRow(isFirst = false, isLast = true) {
            ActivityRow(
                icon = Icons.Rounded.Bookmark,
                tint = Osho.colors.systemOrange,
                title = "Bookmarks",
                subtitle = if (state.bookmarkCount > 0) "${state.bookmarkCount} saved" else null,
                onClick = actions.onOpenBookmarks,
            )
        }
    }
}

@Composable
private fun ActivityRow(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    tint: androidx.compose.ui.graphics.Color,
    title: String,
    subtitle: String?,
    onClick: () -> Unit,
) {
    val colors = Osho.colors
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(role = Role.Button, onClick = onClick)
            .semantics(mergeDescendants = true) {}
            .rowContentPadding(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(24.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = Osho.typography.body, color = colors.label)
            if (subtitle != null) Text(subtitle, style = Osho.typography.caption, color = colors.secondaryLabel)
        }
        Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = colors.tertiaryLabel, modifier = Modifier.size(22.dp))
    }
}

@Composable
private fun SelectionBar(count: Int, onDelete: () -> Unit, modifier: Modifier = Modifier) {
    val colors = Osho.colors
    Row(
        modifier
            .fillMaxWidth()
            .glass(RectangleShape, hazeState = null)
            .padding(horizontal = 20.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            if (count == 0) "Select discourses" else "$count selected",
            style = Osho.typography.subheadline,
            color = colors.secondaryLabel,
            modifier = Modifier.weight(1f),
        )
        Spacer(Modifier.width(12.dp))
        val enabled = count > 0
        Text(
            "Delete",
            style = Osho.typography.body,
            fontWeight = FontWeight.SemiBold,
            color = if (enabled) colors.systemRed else colors.systemRed.copy(alpha = 0.35f),
            modifier = Modifier
                .heightIn(min = 44.dp)
                .clickable(enabled = enabled, role = Role.Button, onClick = onDelete)
                .padding(horizontal = 8.dp, vertical = 11.dp),
        )
    }
}
