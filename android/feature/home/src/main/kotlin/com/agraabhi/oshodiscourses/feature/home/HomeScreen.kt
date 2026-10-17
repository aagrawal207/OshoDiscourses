package com.agraabhi.oshodiscourses.feature.home

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.PauseCircle
import androidx.compose.material.icons.rounded.PlayCircle
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation3.runtime.NavKey
import com.agraabhi.oshodiscourses.core.domain.player.PlayerState
import com.agraabhi.oshodiscourses.core.model.SeriesInfo
import com.agraabhi.oshodiscourses.core.ui.LocalAppServices
import com.agraabhi.oshodiscourses.core.ui.components.LargeTitlePage
import com.agraabhi.oshodiscourses.core.ui.components.SeriesThumbnail
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable

/** The Home tab's root. */
@Serializable
data object HomeRoute : NavKey

/** Sections are capped at the iOS content width plus side padding (640 + 32). */
private val SectionMaxWidth = 672.dp

/**
 * Home (iOS `HomeView`). The support card needs [onOpenSupport], which shows the tip jar and
 * calls `onDismissed` when it closes; the two flags keep the card out of busy moments.
 */
@Composable
fun HomeScreen(
    onOpenSeries: (seriesID: String) -> Unit,
    modifier: Modifier = Modifier,
    onOpenSupport: ((onDismissed: () -> Unit) -> Unit)? = null,
    isPlayerPresented: Boolean = false,
    isOtherSheetPresented: Boolean = false,
) {
    val services = LocalAppServices.current
    val viewModel = viewModel {
        HomeViewModel(services.catalog, services.downloads, services.playbackState, services.player, services.settings)
    }
    val state by viewModel.state.collectAsStateWithLifecycle()
    val support = rememberHomeSupportState(services, onOpenSupport != null, isPlayerPresented, isOtherSheetPresented)

    LargeTitlePage(title = "Home", background = Osho.colors.systemGroupedBackground, modifier = modifier) {
        var first = true
        fun Modifier.sectionTop(): Modifier = padding(top = if (first) 12.dp else 18.dp).also { first = false }

        if (state.continueGroups.isNotEmpty()) {
            val top = Modifier.sectionTop()
            item(key = "continue", contentType = "continue") {
                ContinueListeningSection(
                    groups = state.continueGroups,
                    player = viewModel.playerState,
                    onClearAll = viewModel::clearContinueListening,
                    onOpenSeries = onOpenSeries,
                    onPlay = viewModel::play,
                    onDismiss = viewModel::dismissContinue,
                    coverURL = viewModel::coverURL,
                    modifier = top,
                )
            }
        }
        if (state.recentlyCompleted.isNotEmpty()) {
            val top = Modifier.sectionTop()
            item(key = "completed", contentType = "completed") {
                RecentlyCompletedSection(
                    items = state.recentlyCompleted,
                    onClearAll = viewModel::clearRecentlyCompleted,
                    onOpenSeries = onOpenSeries,
                    onDismiss = viewModel::dismissCompleted,
                    coverURL = viewModel::coverURL,
                    modifier = top,
                )
            }
        }
        if (onOpenSupport != null && support.showsCard) {
            val top = Modifier.sectionTop()
            item(key = "support", contentType = "support") { HomeSupportCard(support, onOpenSupport, top) }
        }
        state.shelves.forEach { shelf ->
            val top = Modifier.sectionTop()
            item(key = "shelf-${shelf.title}", contentType = "shelf") {
                ShelfSection(shelf, onOpenSeries, viewModel::coverURL, top)
            }
        }
    }
}

@Composable
private fun SectionHeaderRow(title: String, onClearAll: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            title,
            style = Osho.typography.title3,
            fontWeight = FontWeight.Bold,
            color = Osho.colors.label,
            modifier = Modifier.weight(1f).semantics { heading() },
        )
        Box(
            modifier = Modifier
                .sizeIn(minWidth = 44.dp, minHeight = 44.dp)
                .clickable(role = Role.Button, onClick = onClearAll),
            contentAlignment = Alignment.Center,
        ) {
            Text("Clear All", style = Osho.typography.caption, color = Osho.colors.accentSecondary)
        }
    }
}

@Composable
private fun SectionCard(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Column(
        modifier
            .padding(horizontal = 16.dp)
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(Osho.colors.secondarySystemGroupedBackground)
            .padding(horizontal = 16.dp),
    ) { content() }
}

@Composable
private fun ContinueListeningSection(
    groups: List<ContinueGroup>,
    player: StateFlow<PlayerState>,
    onClearAll: () -> Unit,
    onOpenSeries: (String) -> Unit,
    onPlay: (ContinueItem) -> Unit,
    onDismiss: (String) -> Unit,
    coverURL: (String) -> String?,
    modifier: Modifier,
) {
    Column(modifier.widthIn(max = SectionMaxWidth), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        SectionHeaderRow("Continue Listening", onClearAll)
        SectionCard {
            groups.forEachIndexed { index, group ->
                ContinueHeader(group, onClick = { onOpenSeries(group.series.id) }, coverURL = coverURL(group.series.id))
                group.items.forEach { item ->
                    ContinueRow(item, player, onPlay = { onPlay(item) }, onDismiss = { onDismiss(item.id) })
                }
                if (index < groups.lastIndex) HorizontalDivider(thickness = 0.5.dp, color = Osho.colors.separator)
            }
        }
    }
}

@Composable
private fun ContinueHeader(group: ContinueGroup, onClick: () -> Unit, coverURL: String?) {
    val colors = Osho.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(role = Role.Button, onClickLabel = "Opens the series", onClick = onClick)
            .padding(top = 12.dp, bottom = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        SeriesThumbnail(group.series.name, 32.dp, coverURL = coverURL)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                group.series.name,
                style = Osho.typography.subheadline,
                fontWeight = FontWeight.SemiBold,
                color = colors.label,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                "${group.series.count} discourses · ${group.items.size} in progress",
                style = Osho.typography.caption2,
                color = colors.secondaryLabel,
            )
        }
        Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = colors.quaternaryLabel, modifier = Modifier.size(18.dp))
    }
}

@Composable
private fun ContinueRow(item: ContinueItem, playerFlow: StateFlow<PlayerState>, onPlay: () -> Unit, onDismiss: () -> Unit) {
    val colors = Osho.colors
    // Only rows read the ticking player, so Home itself does not recompose every half second.
    val player by playerFlow.collectAsStateWithLifecycle()
    val isCurrent = player.currentTrackId == item.id
    val isPlaying = isCurrent && player.isPlaying
    val fraction = HomeContent.progressFraction(item, player)
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(
            modifier = Modifier.weight(1f).clickable(role = Role.Button, onClick = onPlay),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text(
                "Discourse ${item.discourse.number}",
                style = Osho.typography.subheadline,
                color = if (isCurrent) colors.accent else colors.label,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Box(Modifier.fillMaxWidth().height(3.dp).clip(CircleShape).background(colors.label.copy(alpha = 0.1f))) {
                Box(Modifier.fillMaxWidth(fraction).height(3.dp).clip(CircleShape).background(colors.accent))
            }
        }
        Box(
            modifier = Modifier
                .clip(CircleShape)
                .clickable(role = Role.Button, onClick = onPlay)
                .semantics { contentDescription = if (isPlaying) "Pause" else "Play" },
        ) {
            Icon(
                if (isPlaying) Icons.Rounded.PauseCircle else Icons.Rounded.PlayCircle,
                contentDescription = null,
                tint = colors.accent,
                modifier = Modifier.size(scaled(32.dp)),
            )
        }
        DismissButton("Remove from Continue Listening", onDismiss)
    }
}

/** The small × in a faint circle; the hit area is 44 dp while the glyph stays small. */
@Composable
private fun DismissButton(label: String, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .size(44.dp)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier.size(22.dp).clip(CircleShape).background(Osho.colors.label.copy(alpha = 0.08f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Rounded.Close, contentDescription = null, tint = Osho.colors.secondaryLabel, modifier = Modifier.size(14.dp))
        }
    }
}

@Composable
private fun RecentlyCompletedSection(
    items: List<CompletedItem>,
    onClearAll: () -> Unit,
    onOpenSeries: (String) -> Unit,
    onDismiss: (String) -> Unit,
    coverURL: (String) -> String?,
    modifier: Modifier,
) {
    val colors = Osho.colors
    Column(modifier.widthIn(max = SectionMaxWidth), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        SectionHeaderRow("Recently Completed", onClearAll)
        SectionCard {
            items.forEachIndexed { index, item ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable(role = Role.Button, onClick = { onOpenSeries(item.series.id) })
                        .padding(vertical = 8.dp),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    SeriesThumbnail(item.series.name, 48.dp, coverURL = coverURL(item.series.id))
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(
                            "Discourse ${item.discourse.number}",
                            style = Osho.typography.subheadline,
                            fontWeight = FontWeight.SemiBold,
                            color = colors.label,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Text(
                            item.series.name,
                            style = Osho.typography.caption,
                            color = colors.secondaryLabel,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    Icon(Icons.Rounded.CheckCircle, contentDescription = null, tint = colors.systemGreen, modifier = Modifier.size(scaled(24.dp)))
                    DismissButton("Remove from Recently Completed") { onDismiss(item.id) }
                }
                if (index < items.lastIndex) {
                    HorizontalDivider(thickness = 0.5.dp, color = colors.separator, modifier = Modifier.padding(start = 68.dp))
                }
            }
        }
    }
}

@Composable
private fun ShelfSection(shelf: Shelf, onOpenSeries: (String) -> Unit, coverURL: (String) -> String?, modifier: Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            shelf.title,
            style = Osho.typography.subheadline,
            fontWeight = FontWeight.SemiBold,
            color = Osho.colors.label,
            modifier = Modifier.padding(horizontal = 16.dp).semantics { heading() },
        )
        LazyRow(
            contentPadding = PaddingValues(horizontal = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            items(shelf.series, key = { it.id }) { series ->
                ShelfCard(series, coverURL(series.id)) { onOpenSeries(series.id) }
            }
        }
    }
}

@Composable
private fun ShelfCard(series: SeriesInfo, coverURL: String?, onClick: () -> Unit) {
    val colors = Osho.colors
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(8.dp))
            .background(colors.secondarySystemGroupedBackground)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        SeriesThumbnail(series.name, 36.dp, coverURL = coverURL)
        Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(series.name, style = Osho.typography.caption, fontWeight = FontWeight.Medium, color = colors.label, maxLines = 1)
            Text("${series.count} discourses", style = Osho.typography.caption2, color = colors.secondaryLabel, maxLines = 1)
        }
    }
}

/** SF Symbols sized by a text style grow with Dynamic Type; this keeps icons in step with text. */
@Composable
internal fun scaled(base: Dp): Dp = base * LocalDensity.current.fontScale
