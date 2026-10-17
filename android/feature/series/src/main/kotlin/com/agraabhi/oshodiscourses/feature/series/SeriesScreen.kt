package com.agraabhi.oshodiscourses.feature.series

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ArrowCircleDown
import androidx.compose.material.icons.outlined.BookmarkBorder
import androidx.compose.material.icons.outlined.Cancel
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Pause
import androidx.compose.material.icons.outlined.Pending
import androidx.compose.material.icons.outlined.PlayArrow
import androidx.compose.material.icons.rounded.ArrowCircleDown
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.PauseCircle
import androidx.compose.material.icons.rounded.PlayCircle
import androidx.compose.material.icons.rounded.SyncProblem
import androidx.compose.material.icons.rounded.Wifi
import androidx.compose.material.icons.rounded.WifiOff
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.dropShadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.shadow.Shadow
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation3.runtime.NavKey
import com.agraabhi.oshodiscourses.core.domain.downloads.DownloadState
import com.agraabhi.oshodiscourses.core.domain.downloads.WaitingReason
import com.agraabhi.oshodiscourses.core.model.Language
import com.agraabhi.oshodiscourses.core.model.SeriesInfo
import com.agraabhi.oshodiscourses.core.ui.LocalAppServices
import com.agraabhi.oshodiscourses.core.ui.components.ActionSheet
import com.agraabhi.oshodiscourses.core.ui.components.DownloadRing
import com.agraabhi.oshodiscourses.core.ui.components.GlassIconButton
import com.agraabhi.oshodiscourses.core.ui.components.InlineTopBar
import com.agraabhi.oshodiscourses.core.ui.components.MenuAction
import com.agraabhi.oshodiscourses.core.ui.components.OshoMenu
import com.agraabhi.oshodiscourses.core.ui.components.SeriesThumbnail
import com.agraabhi.oshodiscourses.core.ui.tabContentPadding
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import kotlinx.serialization.Serializable

/** A series page, pushed onto whichever tab opened it (Home, Library or Downloads). */
@Serializable
data class SeriesRoute(val seriesID: String) : NavKey

/**
 * Hero header, discourse list, download and play actions (iOS `SeriesDetailView`). Rows play
 * without presenting the player, as on iOS, so [onOpenPlayer] is unused; null callbacks hide their UI.
 */
@Composable
fun SeriesScreen(
    seriesID: String,
    onOpenPlayer: () -> Unit,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
    onOpenTranscript: ((discourseID: String) -> Unit)? = null,
    onAddBookmark: (() -> Unit)? = null,
) {
    val services = LocalAppServices.current
    val viewModel = viewModel(key = "series-$seriesID") {
        SeriesViewModel(
            seriesID = seriesID,
            catalog = services.catalog,
            downloads = services.downloads,
            playbackState = services.playbackState,
            player = services.player,
            transcripts = services.transcripts,
        )
    }
    SeriesContent(
        viewModel = viewModel,
        modifier = modifier,
        onBack = onBack,
        onOpenTranscript = onOpenTranscript,
        onAddBookmark = onAddBookmark,
    )
}

@Composable
internal fun SeriesContent(
    viewModel: SeriesViewModel,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
    onOpenTranscript: ((String) -> Unit)? = null,
    onAddBookmark: (() -> Unit)? = null,
    listState: LazyListState = rememberLazyListState(),
) {
    val colors = Osho.colors
    val series = viewModel.series
    val state by viewModel.state.collectAsStateWithLifecycle()
    var showsMenu by remember { mutableStateOf(false) }
    var confirmsDownloadAll by remember { mutableStateOf(false) }

    Column(modifier.fillMaxSize().background(colors.systemBackground)) {
        InlineTopBar(
            title = series?.name.orEmpty(),
            onBack = onBack,
            modifier = Modifier.statusBarsPadding(),
        ) {
            Box {
                GlassIconButton(
                    icon = Icons.Outlined.Pending,
                    contentDescription = "More options",
                    onClick = { showsMenu = true },
                    tint = colors.accent,
                    iconSize = 24,
                )
                OshoMenu(
                    expanded = showsMenu,
                    onDismiss = { showsMenu = false },
                    actions = listOf(
                        MenuAction("Mark All Complete", Icons.Rounded.CheckCircle) { viewModel.markAll(true) },
                        MenuAction("Mark All Incomplete", Icons.Outlined.Cancel, destructive = true) { viewModel.markAll(false) },
                    ),
                )
            }
        }
        if (series == null) return@Column

        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize(),
            contentPadding = tabContentPadding(PaddingValues(bottom = 16.dp)),
        ) {
            item(key = "header", contentType = "header") {
                SeriesHeader(
                    series = series,
                    completedCount = state.completedCount,
                    transcriptCount = viewModel.transcriptCount,
                    viewModel = viewModel,
                )
            }
            item(key = "downloadAll", contentType = "downloadAll") {
                DownloadAllButton(
                    remaining = state.remainingCount,
                    language = series.language,
                    onClick = { confirmsDownloadAll = true },
                    modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 20.dp),
                )
            }
            state.waitingReason?.let { reason ->
                item(key = "waiting", contentType = "waiting") {
                    WaitingNoticeCard(
                        reason = reason,
                        onUseMobileData = viewModel::useMobileData,
                        modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 8.dp),
                    )
                }
            }
            itemsIndexed(state.rows, key = { _, row -> row.discourse.id }, contentType = { _, _ -> "row" }) { index, row ->
                DiscourseRow(
                    row = row,
                    language = series.language,
                    viewModel = viewModel,
                    onOpenTranscript = onOpenTranscript,
                    onAddBookmark = onAddBookmark,
                )
                if (index < state.rows.lastIndex) {
                    HorizontalDivider(thickness = 0.5.dp, color = colors.separator, modifier = Modifier.padding(start = 52.dp))
                }
            }
        }
    }

    if (confirmsDownloadAll && series != null) {
        val size = DownloadEstimate.totalLabel(state.remainingCount, series.language)
        val remaining = state.remainingCount
        ActionSheet(
            title = "Download $remaining discourses?",
            message = "This will download $remaining discourses using approximately $size of storage.",
            actionLabel = "Download $remaining ($size)",
            onAction = viewModel::downloadAll,
            onDismiss = { confirmsDownloadAll = false },
        )
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun SeriesHeader(series: SeriesInfo, completedCount: Int, transcriptCount: Int, viewModel: SeriesViewModel) {
    val colors = Osho.colors
    val type = Osho.typography
    val thumbShape = RoundedCornerShape(12.dp)
    Column(
        modifier = Modifier.fillMaxWidth().padding(vertical = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        SeriesThumbnail(
            name = series.name,
            size = 120.dp,
            coverURL = LocalAppServices.current.catalog.coverURL(series.id),
            modifier = Modifier.dropShadow(thumbShape, Shadow(radius = 20.dp, color = colors.label.copy(alpha = 0.1f))),
        )
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text(
                series.name,
                style = type.title2,
                fontWeight = FontWeight.Bold,
                color = colors.label,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(horizontal = 16.dp).semantics { heading() },
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("${series.count} discourses", style = type.subheadline, color = colors.secondaryLabel)
                Text("·", style = type.body, color = colors.secondaryLabel)
                Text(languageName(series.language), style = type.subheadline, color = colors.accent)
            }
            if (completedCount > 0) {
                Text("$completedCount/${series.count} completed", style = type.caption, color = colors.systemGreen)
            }
            if (transcriptCount > 0) {
                LabelRow(Icons.Outlined.Description, iconSize = scaled(14.dp), tint = colors.secondaryLabel) {
                    Text(
                        if (transcriptCount == series.count) "Transcripts for every discourse" else "Transcripts for $transcriptCount of ${series.count}",
                        style = type.caption,
                        color = colors.secondaryLabel,
                    )
                }
            }
            viewModel.description?.let { meta ->
                Column(
                    modifier = Modifier.padding(top = 8.dp, start = 16.dp, end = 16.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(
                        meta.sourceText,
                        style = type.caption,
                        color = colors.secondaryLabel,
                        textAlign = TextAlign.Center,
                        maxLines = 4,
                        overflow = TextOverflow.Ellipsis,
                    )
                    if (meta.year != null && meta.location != null) {
                        Text("${meta.location}, ${meta.year}", style = type.caption2, color = colors.tertiaryLabel)
                    }
                    if (meta.themes.isNotEmpty()) {
                        FlowRow(
                            horizontalArrangement = Arrangement.spacedBy(4.dp),
                            verticalArrangement = Arrangement.spacedBy(4.dp),
                        ) {
                            meta.themes.take(5).forEach { theme ->
                                Text(
                                    theme,
                                    fontSize = 10.sp,
                                    lineHeight = 12.sp,
                                    color = colors.accent,
                                    modifier = Modifier
                                        .clip(CircleShape)
                                        .background(colors.accent.copy(alpha = 0.1f))
                                        .padding(horizontal = 8.dp, vertical = 3.dp),
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

private fun languageName(language: Language): String = if (language == Language.HINDI) "Hindi" else "English"

@Composable
private fun DownloadAllButton(remaining: Int, language: Language, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val colors = Osho.colors
    val type = Osho.typography
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(colors.accent.copy(alpha = 0.15f))
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 12.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Rounded.ArrowCircleDown, contentDescription = null, tint = colors.accent, modifier = Modifier.size(scaled(18.dp)))
        Spacer(Modifier.width(8.dp))
        Text("Download All", style = type.subheadline, fontWeight = FontWeight.SemiBold, color = colors.accent)
        if (remaining > 0) {
            Spacer(Modifier.width(8.dp))
            Text(
                "($remaining · ${DownloadEstimate.totalLabel(remaining, language)})",
                style = type.subheadline,
                color = colors.accent.copy(alpha = 0.8f),
                textAlign = TextAlign.Center,
                modifier = Modifier.weight(1f, fill = false),
            )
        }
    }
}

@Composable
private fun WaitingNoticeCard(reason: WaitingReason, onUseMobileData: () -> Unit, modifier: Modifier = Modifier) {
    val colors = Osho.colors
    val type = Osho.typography
    Column(
        modifier = modifier
            .fillMaxWidth()
            .background(colors.secondarySystemBackground, RoundedCornerShape(12.dp))
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        LabelRow(if (reason == WaitingReason.WIFI) Icons.Rounded.Wifi else Icons.Rounded.WifiOff, iconSize = scaled(18.dp), tint = colors.label) {
            Text(WaitingNotice.label(reason), style = type.subheadline, fontWeight = FontWeight.SemiBold, color = colors.label)
        }
        Text(WaitingNotice.body(reason), style = type.footnote, color = colors.secondaryLabel)
        if (reason == WaitingReason.WIFI) {
            Text(
                WaitingNotice.USE_MOBILE_DATA,
                style = type.body,
                color = colors.onAccent,
                modifier = Modifier
                    .clip(CircleShape)
                    .background(colors.accent)
                    .clickable(role = Role.Button, onClickLabel = WaitingNotice.USE_MOBILE_DATA_HINT, onClick = onUseMobileData)
                    .padding(horizontal = 14.dp, vertical = 7.dp),
            )
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun DiscourseRow(
    row: DiscourseRowState,
    language: Language,
    viewModel: SeriesViewModel,
    onOpenTranscript: ((String) -> Unit)?,
    onAddBookmark: (() -> Unit)?,
) {
    val colors = Osho.colors
    val type = Osho.typography
    val density = LocalDensity.current
    val haptics = LocalHapticFeedback.current
    var showsMenu by remember { mutableStateOf(false) }
    var pressAt by remember { mutableStateOf(Offset.Zero) }
    var rowHeight by remember { mutableStateOf(0) }
    val id = row.discourse.id

    Box {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .pointerInput(Unit) {
                    // Remembers where the finger went down so the menu opens at the touch point.
                    awaitEachGesture {
                        pressAt = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial).position
                        rowHeight = size.height
                    }
                }
                .combinedClickable(
                    role = Role.Button,
                    onClickLabel = if (row.isDownloaded) "Plays this discourse" else "Downloads this discourse",
                    onLongClickLabel = "More options",
                    onLongClick = {
                        haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                        showsMenu = true
                    },
                    onClick = { viewModel.onRowTap(id) },
                )
                .semantics(mergeDescendants = true) { contentDescription = row.accessibilityLabel }
                .padding(horizontal = 16.dp, vertical = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(Modifier.width(28.dp).clearAndSetSemantics {}, contentAlignment = Alignment.Center) {
                Text("${row.discourse.number}", style = type.subheadline, color = colors.secondaryLabel, maxLines = 1)
                if (row.isCompleted) {
                    Icon(
                        Icons.Rounded.CheckCircle,
                        contentDescription = null,
                        tint = colors.systemGreen,
                        modifier = Modifier.offset(x = 10.dp, y = (-8).dp).size(12.dp),
                    )
                }
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Row(
                    modifier = Modifier.clearAndSetSemantics {},
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        "Discourse ${row.discourse.number}",
                        style = type.body,
                        color = if (row.isCurrentlyPlaying) colors.systemBlue else colors.label,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                    if (row.hasTranscript) {
                        Icon(Icons.Outlined.Description, contentDescription = null, tint = colors.tertiaryLabel, modifier = Modifier.size(scaled(13.dp)))
                    }
                }
                val failure = row.failureMessage
                val waiting = row.waitingLabel
                when {
                    failure != null -> Text(failure, style = type.caption2, color = colors.systemRed)
                    waiting != null -> Text(waiting, style = type.caption2, color = colors.secondaryLabel)
                    else -> AnimatedVisibility(visible = row.showsDownloadHint, enter = fadeIn(), exit = fadeOut()) {
                        Text("Downloading...", style = type.caption2, color = colors.secondaryLabel)
                    }
                }
            }
            RowAction(row, language, onClick = { viewModel.onActionTap(id) })
        }

        OshoMenu(
            expanded = showsMenu,
            onDismiss = { showsMenu = false },
            offset = with(density) { DpOffset(pressAt.x.toDp(), (pressAt.y - rowHeight).toDp()) },
            actions = buildList {
                if (row.isDownloaded) {
                    val pausing = row.isCurrentlyPlaying
                    add(MenuAction(if (pausing) "Pause" else "Play", if (pausing) Icons.Outlined.Pause else Icons.Outlined.PlayArrow) { viewModel.togglePlayback(id) })
                } else if (!row.isActive) {
                    add(MenuAction("Download", Icons.Outlined.ArrowCircleDown) { viewModel.download(id) })
                }
                if (row.isCurrentTrack && onAddBookmark != null) {
                    add(MenuAction("Add Bookmark…", Icons.Outlined.BookmarkBorder, onClick = onAddBookmark))
                }
                if (row.hasTranscript && onOpenTranscript != null) {
                    add(MenuAction("Read Transcript", Icons.Outlined.Description) { onOpenTranscript(id) })
                }
                if (row.isCompleted) {
                    add(MenuAction("Mark as Incomplete", Icons.Outlined.Cancel) { viewModel.setCompleted(id, false) })
                } else {
                    add(MenuAction("Mark as Complete", Icons.Outlined.CheckCircle) { viewModel.setCompleted(id, true) })
                }
                if (row.isDownloaded) {
                    add(MenuAction("Remove Download", Icons.Outlined.Delete, destructive = true, dividerBefore = true) { viewModel.removeDownload(id) })
                }
            },
        )
    }
}

@Composable
private fun RowAction(row: DiscourseRowState, language: Language, onClick: () -> Unit) {
    val colors = Osho.colors
    val download = row.download
    when {
        row.isActive -> {
            val queued = download == DownloadState.Queued
            val progress = (download as? DownloadState.Downloading)?.progress ?: 0.0
            // Smaller than 48 dp on purpose, as on iOS; Compose still expands the touch bounds.
            Box(
                modifier = Modifier
                    .size(32.dp)
                    .clip(CircleShape)
                    .clickable(role = Role.Button, onClick = onClick)
                    .semantics {
                        contentDescription = "Cancel download"
                        stateDescription = if (queued) "Queued" else "${(progress * 100).toInt()} percent"
                    },
                contentAlignment = Alignment.Center,
            ) {
                DownloadRing(progress = progress.toFloat(), queued = queued)
            }
        }
        download is DownloadState.Failed -> IconAction(Icons.Rounded.SyncProblem, "Retry download", colors.systemRed, scaled(26.dp), onClick)
        row.isDownloaded -> {
            val pausing = row.isCurrentlyPlaying
            IconAction(
                if (pausing) Icons.Rounded.PauseCircle else Icons.Rounded.PlayCircle,
                if (pausing) "Pause" else "Play",
                colors.accent,
                scaled(32.dp),
                onClick,
            )
        }
        else -> Text(
            "GET ${DownloadEstimate.perDiscourseLabel(language)}",
            style = Osho.typography.caption,
            fontWeight = FontWeight.Bold,
            color = colors.accent,
            maxLines = 1,
            softWrap = false,
            modifier = Modifier
                .clip(CircleShape)
                .background(colors.accent.copy(alpha = 0.15f))
                .clickable(role = Role.Button, onClick = onClick)
                .padding(horizontal = 10.dp, vertical = 6.dp),
        )
    }
}

@Composable
private fun IconAction(icon: ImageVector, label: String, tint: Color, size: Dp, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .size(size)
            .clip(CircleShape)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(size))
    }
}

/** SF Symbols sized by a text style grow with Dynamic Type; this keeps icons in step with text. */
@Composable
internal fun scaled(base: Dp): Dp = base * LocalDensity.current.fontScale
