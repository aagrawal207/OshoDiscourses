package com.agraabhi.oshodiscourses.feature.transcript

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandHorizontally
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkHorizontally
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.animateScrollBy
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.interaction.DragInteraction
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.FormatAlignLeft
import androidx.compose.material.icons.rounded.ArrowDownward
import androidx.compose.material.icons.rounded.ArrowUpward
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.CheckCircleOutline
import androidx.compose.material.icons.rounded.ContentCopy
import androidx.compose.material.icons.rounded.Expand
import androidx.compose.material.icons.rounded.MyLocation
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.RadioButtonUnchecked
import androidx.compose.material.icons.rounded.Share
import androidx.compose.material.icons.rounded.TextFields
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.onLongClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.Velocity
import androidx.compose.ui.unit.dp
import com.agraabhi.oshodiscourses.core.ui.components.CappedFontScale
import com.agraabhi.oshodiscourses.core.ui.components.OshoMenu
import com.agraabhi.oshodiscourses.core.ui.components.OshoMenuItem
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import com.agraabhi.oshodiscourses.feature.transcript.text.RowID
import com.agraabhi.oshodiscourses.feature.transcript.text.TranscriptRow
import com.agraabhi.oshodiscourses.feature.transcript.text.TranscriptSearch
import com.agraabhi.oshodiscourses.feature.transcript.text.TranscriptSentences
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlin.math.abs

/** Where the spoken row sits, as a share of the viewport from the top. */
private const val READING_LINE = 0.35f

/** The scrolling column of rows with the Now playing pill floating over it. */
@Composable
internal fun TranscriptReader(state: TranscriptUiState, vm: TranscriptViewModel, modifier: Modifier = Modifier) {
    val listState = rememberLazyListState()
    val density = LocalDensity.current
    val focusManager = LocalFocusManager.current
    val dragThreshold = with(density) { 24.dp.toPx() }
    val flingThreshold = with(density) { 300.dp.toPx() }
    val currentVm by rememberUpdatedState(vm)

    LaunchedEffect(vm, listState) {
        vm.scrollCommands.collect { listState.bringToReadingLine(it) }
    }
    LaunchedEffect(listState) {
        snapshotFlow { listState.rowAtReadingLine() }
            .distinctUntilChanged()
            .collect { index ->
                val rows = currentVm.state.value.rows
                if (index != null && index in rows.indices) currentVm.onScrolledRowChanged(rows[index].id)
            }
    }
    val connection = remember(listState) { UserScrollConnection(dragThreshold, flingThreshold) { focusManager.clearFocus(); currentVm.onUserScroll() } }
    LaunchedEffect(listState) {
        listState.interactionSource.interactions.collect { if (it is DragInteraction.Start) connection.dragged = 0f }
    }

    Box(modifier.fillMaxSize()) {
        BoxWithConstraints(
            Modifier
                .fillMaxSize()
                .nestedScroll(connection)
                .pointerInput(Unit) { detectTapGestures(onTap = { currentVm.onBackgroundTap() }) },
            contentAlignment = Alignment.TopCenter,
        ) {
            LazyColumn(
                state = listState,
                modifier = Modifier.widthIn(max = 720.dp).fillMaxSize(),
                contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 8.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                val currentOrdinal = state.currentOrdinal
                itemsIndexed(state.rows, key = { _, row -> rowKey(row.id) }) { _, row ->
                    val isCurrent = state.isPlayingThis && row.id == state.currentRow
                    TranscriptRowItem(
                        row = row,
                        isCurrent = isCurrent,
                        isPast = state.isPlayingThis && (currentOrdinal ?: 0) > row.ordinal,
                        isTapped = state.tappedRow == row.id,
                        isPicked = state.isSelecting && row.id in state.selection,
                        isSelecting = state.isSelecting,
                        showsPlaybackChips = state.isPlayingThis,
                        sentence = if (isCurrent) state.currentSentence else null,
                        query = if (state.isSearching) TranscriptSearch.normalizedQuery(state.searchQuery) else null,
                        fontSize = state.fontSize.toFloat(),
                        vm = vm,
                    )
                }
                // Room to bring the last rows up to the reading line.
                item(key = "end") { Spacer(Modifier.height(240.dp)) }
            }
        }

        // Rows fade under the toolbar instead of being cut mid-line.
        Box(
            Modifier
                .fillMaxWidth()
                .height(12.dp)
                .background(Brush.verticalGradient(listOf(Osho.colors.systemBackground, Osho.colors.systemBackground.copy(alpha = 0f)))),
        )

        AnimatedVisibility(
            visible = state.showsNowPlaying,
            enter = fadeIn(tween(200)) + androidx.compose.animation.slideInVertically(tween(200)) { it },
            exit = fadeOut(tween(200)) + androidx.compose.animation.slideOutVertically(tween(200)) { it },
            modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 12.dp),
        ) {
            NowPlayingPill(below = state.nowPlayingIsBelow, onClick = vm::resumeFollowing)
        }
    }
}

/** Only a finger that moved the content past 24 dp, or a fling, counts as the reader scrolling. */
private class UserScrollConnection(
    private val dragThreshold: Float,
    private val flingThreshold: Float,
    private val onUserScroll: () -> Unit,
) : NestedScrollConnection {
    var dragged = 0f

    override fun onPostScroll(consumed: Offset, available: Offset, source: NestedScrollSource): Offset {
        if (source == NestedScrollSource.UserInput) {
            dragged += abs(consumed.y)
            if (dragged > dragThreshold) onUserScroll()
        }
        return Offset.Zero
    }

    override suspend fun onPreFling(available: Velocity): Velocity {
        if (abs(available.y) > flingThreshold) onUserScroll()
        return Velocity.Zero
    }
}

private fun LazyListState.readingLine(): Float {
    val info = layoutInfo
    return info.viewportStartOffset + (info.viewportEndOffset - info.viewportStartOffset) * READING_LINE
}

private fun LazyListState.rowAtReadingLine(): Int? {
    val info = layoutInfo
    if (info.visibleItemsInfo.isEmpty()) return null
    val line = readingLine()
    val hit = info.visibleItemsInfo.firstOrNull { it.key != "end" && it.offset + it.size > line }
        ?: info.visibleItemsInfo.lastOrNull { it.key != "end" }
    return hit?.index
}

/** Aligns the row's 35 % point with the viewport's 35 % line, like iOS `scrollPosition(anchor:)`. */
private suspend fun LazyListState.bringToReadingLine(command: ScrollCommand) {
    snapshotFlow { layoutInfo.viewportSize.height }.first { it > 0 }
    if (command.ordinal >= layoutInfo.totalItemsCount - 1) return
    val visible = layoutInfo.visibleItemsInfo.firstOrNull { it.index == command.ordinal }
    if (visible != null && command.motion != ScrollMotion.JUMP) {
        val delta = visible.offset - (readingLine() - visible.size * READING_LINE)
        animateScrollBy(delta, tween(command.motion.millis, easing = FastOutSlowInEasing))
        return
    }
    scrollToItem(command.ordinal)
    val item = layoutInfo.visibleItemsInfo.firstOrNull { it.index == command.ordinal } ?: return
    scrollBy(item.offset - (readingLine() - item.size * READING_LINE))
}

@Composable
private fun NowPlayingPill(below: Boolean, onClick: () -> Unit) {
    val colors = Osho.colors
    CappedFontScale {
        Row(
            modifier = Modifier
                .shadow(8.dp, CircleShape, ambientColor = Color.Black.copy(alpha = 0.2f), spotColor = Color.Black.copy(alpha = 0.2f))
                .clip(CircleShape)
                .background(colors.accent)
                .clickable(role = Role.Button, onClickLabel = "Scrolls back to the paragraph being spoken", onClick = onClick)
                .padding(horizontal = 16.dp, vertical = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(if (below) Icons.Rounded.ArrowDownward else Icons.Rounded.ArrowUpward, null, tint = Color.White, modifier = Modifier.size(16.dp))
            Text("Now playing", style = Osho.typography.subheadline, fontWeight = FontWeight.SemiBold, color = Color.White)
        }
    }
}

@Composable
private fun TranscriptRowItem(
    row: TranscriptRow,
    isCurrent: Boolean,
    isPast: Boolean,
    isTapped: Boolean,
    isPicked: Boolean,
    isSelecting: Boolean,
    showsPlaybackChips: Boolean,
    sentence: Int?,
    query: String?,
    fontSize: Float,
    vm: TranscriptViewModel,
) {
    val colors = Osho.colors
    val density = LocalDensity.current
    val haptics = LocalHapticFeedback.current
    val currentVm by rememberUpdatedState(vm)
    val currentRow by rememberUpdatedState(row)

    val background by animateColorAsState(
        when {
            isPicked -> colors.accent.copy(alpha = 0.14f)
            isCurrent -> colors.accent.copy(alpha = 0.10f)
            isTapped -> colors.label.copy(alpha = 0.05f)
            else -> colors.accent.copy(alpha = 0f)
        },
        tween(250, easing = FastOutSlowInEasing),
        label = "rowBackground",
    )
    val textColor by animateColorAsState(
        if (isCurrent || isTapped || isPicked) colors.label else colors.label.copy(alpha = if (isPast) 0.45f else 0.6f),
        tween(250, easing = FastOutSlowInEasing),
        label = "rowText",
    )
    val barAlpha by animateFloatAsState(if (isCurrent && !isSelecting) 1f else 0f, tween(250), label = "rowBar")

    // Fixed sizes, as on iOS: the reader has its own size control instead of Dynamic Type.
    val textStyle = remember(fontSize, isCurrent, row.isEmphasis, density) {
        with(density) {
            TextStyle(
                fontSize = fontSize.dp.toSp(),
                lineHeight = (fontSize * 1.48f).dp.toSp(),
                fontWeight = if (isCurrent) FontWeight.SemiBold else FontWeight.Normal,
                fontFamily = if (row.isEmphasis) FontFamily.Serif else FontFamily.Default,
                fontStyle = if (row.isEmphasis) FontStyle.Italic else FontStyle.Normal,
            )
        }
    }
    val dimmed = colors.label.copy(alpha = 0.55f)
    val matchColor = colors.systemYellow.copy(alpha = 0.45f)
    val text = remember(row.text, sentence, query, dimmed, matchColor) { rowText(row.text, sentence, query, dimmed, matchColor) }

    var menuAt by remember { mutableStateOf<Offset?>(null) }
    var rowHeight by remember { mutableStateOf(0) }
    val hint = when {
        isSelecting -> if (isPicked) "Tap to deselect" else "Tap to select"
        isTapped -> ""
        else -> "Tap for play, sync, copy and share"
    }

    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(background)
            .drawWithContent {
                drawContent()
                if (barAlpha > 0f) {
                    val inset = 12.dp.toPx()
                    drawRoundRect(
                        color = colors.accent.copy(alpha = barAlpha),
                        topLeft = Offset(0f, inset),
                        size = Size(3.dp.toPx(), (size.height - 2 * inset).coerceAtLeast(0f)),
                        cornerRadius = CornerRadius(2.dp.toPx()),
                    )
                }
            }
            .padding(horizontal = 12.dp)
            .padding(top = if (row.isFirstInParagraph) 10.dp else 3.dp, bottom = if (row.isLastInParagraph) 10.dp else 3.dp),
    ) {
        Box(
            Modifier
                .fillMaxWidth()
                .onSizeChanged { rowHeight = it.height }
                .pointerInput(Unit) {
                    detectTapGestures(
                        onTap = { currentVm.onRowTap(currentRow) },
                        onLongPress = { offset ->
                            if (hasMenu(currentVm, currentRow)) {
                                haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                                menuAt = offset
                            }
                        },
                    )
                }
                .semantics(mergeDescendants = true) {
                    role = Role.Button
                    selected = if (isSelecting) isPicked else isCurrent
                    onClick(label = hint.ifEmpty { null }) { currentVm.onRowTap(currentRow); true }
                    onLongClick { if (hasMenu(currentVm, currentRow)) menuAt = Offset.Zero; true }
                    customActions = listOf(
                        CustomAccessibilityAction("Copy") { currentVm.copy(listOf(currentRow)); true },
                        CustomAccessibilityAction("Select Text") { currentVm.openTextSelection(listOf(currentRow)); true },
                    )
                },
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                AnimatedVisibility(
                    visible = isSelecting,
                    enter = fadeIn(tween(200)) + expandHorizontally(tween(200)),
                    exit = fadeOut(tween(200)) + shrinkHorizontally(tween(200)),
                ) {
                    val iconSize = minOf(fontSize, 22f)
                    val lineHeight = fontSize * 1.48f
                    Icon(
                        if (isPicked) Icons.Rounded.CheckCircle else Icons.Rounded.RadioButtonUnchecked,
                        contentDescription = null,
                        tint = if (isPicked) colors.accent else colors.secondaryLabel,
                        modifier = Modifier.padding(top = ((lineHeight - iconSize) / 2).dp).size(iconSize.dp),
                    )
                }
                Text(text, style = textStyle, color = textColor, modifier = Modifier.weight(1f))
            }
            RowMenu(
                anchorAt = menuAt,
                rowHeight = rowHeight,
                row = row,
                vm = vm,
                onDismiss = { menuAt = null },
            )
        }
        AnimatedVisibility(
            visible = isTapped && !isSelecting,
            enter = fadeIn(tween(200)) + expandVertically(tween(200), expandFrom = Alignment.Top),
            exit = fadeOut(tween(200)) + shrinkVertically(tween(200), shrinkTowards = Alignment.Top),
        ) {
            ActionChips(row, showsPlaybackChips, vm, Modifier.padding(top = 10.dp))
        }
    }
}

private fun hasMenu(vm: TranscriptViewModel, row: TranscriptRow): Boolean =
    !vm.state.value.isSelecting || vm.canSelectUpToHere(row) || vm.canSelectWholeParagraph(row)

/** Highlights search matches and, in the spoken row, dims every sentence but the current one. */
internal fun rowText(text: String, sentence: Int?, query: String?, dimmed: Color, matchColor: Color): AnnotatedString =
    buildAnnotatedString {
        append(text)
        if (sentence != null) {
            val ranges = TranscriptSentences.ranges(text)
            if (ranges.size > 1) {
                ranges.forEachIndexed { i, r -> if (i != sentence) addStyle(SpanStyle(color = dimmed), r.start, r.end) }
            }
        }
        if (query != null) {
            for (m in TranscriptSearch.matches(text, query)) addStyle(SpanStyle(background = matchColor), m.start, m.end)
        }
    }

@Composable
private fun RowMenu(anchorAt: Offset?, rowHeight: Int, row: TranscriptRow, vm: TranscriptViewModel, onDismiss: () -> Unit) {
    val density = LocalDensity.current
    val at = anchorAt ?: Offset.Zero
    // DropdownMenu offsets from the anchor's bottom edge, so lift it back to the touch point.
    val offset = with(density) { DpOffset(at.x.toDp(), (at.y - rowHeight).toDp()) }
    val selecting = vm.state.value.isSelecting
    OshoMenu(expanded = anchorAt != null, onDismiss = onDismiss, offset = offset) {
        fun act(block: () -> Unit) {
            onDismiss()
            block()
        }
        if (selecting) {
            if (vm.canSelectUpToHere(row)) OshoMenuItem("Select Up to Here", Icons.Rounded.Expand, { act { vm.selectUpToHere(row) } })
            if (vm.canSelectWholeParagraph(row)) {
                OshoMenuItem("Select Whole Paragraph", Icons.AutoMirrored.Rounded.FormatAlignLeft, { act { vm.selectWholeParagraph(row) } })
            }
        } else {
            OshoMenuItem("Copy", Icons.Rounded.ContentCopy, { act { vm.copy(listOf(row)) } })
            OshoMenuItem("Select Text", Icons.Rounded.TextFields, { act { vm.openTextSelection(listOf(row)) } })
            OshoMenuItem("Select Passages", Icons.Rounded.CheckCircleOutline, { act { vm.startSelecting(row) } })
            OshoMenuItem("Share", Icons.Rounded.Share, { act { vm.share(listOf(row)) } })
        }
    }
}

@Composable
private fun ActionChips(row: TranscriptRow, playing: Boolean, vm: TranscriptViewModel, modifier: Modifier = Modifier) {
    Row(
        modifier.horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (playing) {
            ActionChip("Play from here", Icons.Rounded.PlayArrow) { vm.playFromHere(row) }
            ActionChip("Audio is here", Icons.Rounded.MyLocation) { vm.anchorHere(row) }
        }
        ActionChip("Copy", Icons.Rounded.ContentCopy) { vm.copy(listOf(row)) }
        ActionChip("Select", Icons.Rounded.CheckCircleOutline) { vm.startSelecting(row) }
        ActionChip("Share", Icons.Rounded.Share) { vm.share(listOf(row)) }
    }
}

@Composable
private fun ActionChip(title: String, icon: ImageVector, onClick: () -> Unit) {
    val accent = Osho.colors.accent
    Row(
        Modifier
            .clip(CircleShape)
            .background(accent.copy(alpha = 0.14f))
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = accent, modifier = Modifier.size(15.dp))
        Text(title, style = Osho.typography.footnote, fontWeight = FontWeight.Medium, color = accent, maxLines = 1)
    }
}

/** Stable LazyColumn key for a row. */
internal fun rowKey(id: RowID): String = "${id.paragraph}.${id.index}"
