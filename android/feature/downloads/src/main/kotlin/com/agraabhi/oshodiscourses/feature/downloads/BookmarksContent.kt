package com.agraabhi.oshodiscourses.feature.downloads

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ArrowCircleDown
import androidx.compose.material.icons.outlined.BookmarkBorder
import androidx.compose.material.icons.outlined.BookmarkRemove
import androidx.compose.material.icons.outlined.Psychology
import androidx.compose.material.icons.outlined.Replay
import androidx.compose.material.icons.outlined.SelfImprovement
import androidx.compose.material.icons.outlined.Sell
import androidx.compose.material.icons.outlined.SentimentSatisfied
import androidx.compose.material.icons.rounded.Bookmark
import androidx.compose.material.icons.rounded.PlayCircle
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.agraabhi.oshodiscourses.core.domain.bookmarks.BookmarkCategory
import com.agraabhi.oshodiscourses.core.ui.components.BackGlassButton
import com.agraabhi.oshodiscourses.core.ui.components.CardRow
import com.agraabhi.oshodiscourses.core.ui.components.EmptyState
import com.agraabhi.oshodiscourses.core.ui.components.GroupedPage
import com.agraabhi.oshodiscourses.core.ui.components.OshoFilterChip
import com.agraabhi.oshodiscourses.core.ui.components.SmallSpinner
import com.agraabhi.oshodiscourses.core.ui.components.rowContentPadding
import com.agraabhi.oshodiscourses.core.ui.components.sectionHeader
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import com.agraabhi.oshodiscourses.core.ui.theme.monospacedDigits

/** iOS `BookmarkCategory.icon` mapped to Material Symbols (ui-style.md §4). */
internal val BookmarkCategory.icon: ImageVector
    get() = when (this) {
        BookmarkCategory.RELISTEN -> Icons.Outlined.Replay
        BookmarkCategory.FUNNY -> Icons.Outlined.SentimentSatisfied
        BookmarkCategory.AWESOME -> Icons.Rounded.Star
        BookmarkCategory.PROFOUND -> Icons.Outlined.Psychology
        BookmarkCategory.MEDITATION -> Icons.Outlined.SelfImprovement
        BookmarkCategory.CUSTOM -> Icons.Outlined.Sell
    }

internal class BookmarksActions(
    val onSelectFilter: (BookmarkCategory?) -> Unit = {},
    val onPlay: (String) -> Unit = {},
    val onDownload: (String) -> Unit = {},
    val onDelete: (String) -> Unit = {},
    val onBack: (() -> Unit)? = null,
)

@Composable
internal fun BookmarksContent(state: BookmarksUiState, actions: BookmarksActions, modifier: Modifier = Modifier) {
    GroupedPage(
        title = "Bookmarks",
        largeTitle = true,
        background = Osho.colors.systemBackground,
        modifier = modifier,
        navigation = actions.onBack?.let { back -> { BackGlassButton(back, hazeState = null) } },
    ) {
        if (!state.hasBookmarks) {
            item(key = "empty", contentType = "empty") {
                Box(Modifier.fillParentMaxHeight(0.7f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                    EmptyState(Icons.Outlined.BookmarkBorder, "No Bookmarks", "Tap the bookmark icon in the player to save a moment.")
                }
            }
            return@GroupedPage
        }
        item(key = "chips", contentType = "chips") {
            LazyRow(
                modifier = Modifier.testTag("bookmarks.chips"),
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 10.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                item(key = "all") {
                    OshoFilterChip("All", selected = state.filter == null, onClick = { actions.onSelectFilter(null) }, icon = Icons.Rounded.Bookmark)
                }
                items(BookmarkCategory.entries, key = { it.rawValue }) { category ->
                    OshoFilterChip(
                        category.rawValue,
                        selected = state.filter == category,
                        onClick = { actions.onSelectFilter(category) },
                        icon = category.icon,
                    )
                }
            }
        }
        if (state.groups.isEmpty()) {
            item(key = "filteredEmpty", contentType = "empty") {
                EmptyState(
                    Icons.Outlined.BookmarkRemove,
                    "No bookmarks in this category",
                    "Try a different filter.",
                    Modifier.padding(top = 16.dp),
                )
            }
            return@GroupedPage
        }
        state.groups.forEachIndexed { groupIndex, group ->
            sectionHeader("header.${group.seriesName}", group.seriesName, first = groupIndex == 0)
            itemsIndexed(group.rows, key = { _, row -> row.bookmark.id }, contentType = { _, _ -> "bookmark" }) { index, row ->
                CardRow(
                    isFirst = index == 0,
                    isLast = index == group.rows.lastIndex,
                    onSwipeDelete = { actions.onDelete(row.bookmark.id) },
                ) {
                    BookmarkRow(row, actions)
                }
            }
        }
    }
}

@Composable
private fun BookmarkRow(row: BookmarkRowState, actions: BookmarksActions) {
    val colors = Osho.colors
    val bookmark = row.bookmark
    Row(
        Modifier.fillMaxWidth().rowContentPadding(vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(Modifier.weight(1f).semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                bookmark.title,
                style = Osho.typography.subheadline,
                color = if (row.isPlaying) colors.systemBlue else colors.label,
                maxLines = 1,
            )
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Row(
                    Modifier
                        .clip(CircleShape)
                        .background(colors.accent.copy(alpha = 0.12f))
                        .padding(horizontal = 6.dp, vertical = 2.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(3.dp),
                ) {
                    Icon(bookmark.category.icon, contentDescription = null, tint = colors.accent, modifier = Modifier.size(10.dp))
                    Text(bookmark.displayCategory, style = Osho.typography.caption2, color = colors.accent, maxLines = 1)
                }
                Text(bookmark.formattedTimestamp, style = Osho.typography.caption.monospacedDigits(), color = colors.secondaryLabel)
            }
            if (bookmark.note.isNotEmpty()) {
                Text(bookmark.note, style = Osho.typography.caption, color = colors.secondaryLabel, maxLines = 2)
            }
        }
        when (row.availability) {
            BookmarkAvailability.DOWNLOADED -> TrailingIcon(Icons.Rounded.PlayCircle, "Play", "Plays from the bookmarked moment") {
                actions.onPlay(bookmark.id)
            }
            BookmarkAvailability.DOWNLOADING -> Box(
                Modifier.size(44.dp).semantics { contentDescription = "Downloading" },
                contentAlignment = Alignment.Center,
            ) { SmallSpinner() }
            BookmarkAvailability.NOT_DOWNLOADED -> TrailingIcon(Icons.Outlined.ArrowCircleDown, "Download", null) {
                actions.onDownload(bookmark.discourseID)
            }
        }
    }
}

@Composable
private fun TrailingIcon(icon: ImageVector, label: String, hint: String?, onClick: () -> Unit) {
    Box(
        Modifier
            .size(44.dp)
            .clip(CircleShape)
            .clickable(role = Role.Button, onClickLabel = hint, onClick = onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = Osho.colors.accent, modifier = Modifier.size(28.dp))
    }
}
