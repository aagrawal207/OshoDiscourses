package com.agraabhi.oshodiscourses.feature.player

import android.content.Context
import android.content.Intent
import android.media.MediaRouter2
import android.os.Build
import android.provider.Settings
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animate
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.FormatListBulleted
import androidx.compose.material.icons.automirrored.rounded.Undo
import androidx.compose.material.icons.outlined.Bedtime
import androidx.compose.material.icons.outlined.BookmarkBorder
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.SpeakerGroup
import androidx.compose.material.icons.outlined.Speed
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.FastForward
import androidx.compose.material.icons.rounded.FastRewind
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.PauseCircle
import androidx.compose.material.icons.rounded.PlayCircle
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.ripple
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.Velocity
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.max
import androidx.compose.ui.unit.min
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.agraabhi.oshodiscourses.core.model.PlaybackSpeed
import com.agraabhi.oshodiscourses.core.ui.components.AnchoredPopover
import com.agraabhi.oshodiscourses.core.ui.components.DisabledAlpha
import com.agraabhi.oshodiscourses.core.ui.components.IosSlider
import com.agraabhi.oshodiscourses.core.ui.components.SheetDetent
import com.agraabhi.oshodiscourses.core.ui.components.SheetHost
import com.agraabhi.oshodiscourses.core.ui.components.SkipIntervalIcon
import com.agraabhi.oshodiscourses.core.ui.components.glass
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import com.agraabhi.oshodiscourses.core.ui.theme.ProvideElevatedSurfaces
import com.agraabhi.oshodiscourses.core.ui.theme.monospacedDigits
import com.agraabhi.oshodiscourses.feature.player.components.PortraitArtwork
import com.agraabhi.oshodiscourses.feature.player.components.ShrinkToFitText
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

internal enum class PlayerPopover { SPEED, SLEEP }

internal enum class PlayerSheet { QUEUE, DENOISE, BOOKMARK }

/**
 * The full player, modal over the tabs (iOS `PlayerView`, ui-style.md §6.4). Swipe down or back
 * closes it through [onDismiss]. [onOpenSeries] closes it and pushes the series on Home, as iOS
 * does from the series title. [onShowOutputSwitcher] replaces the system output switcher.
 */
@Composable
fun PlayerScreen(
    onDismiss: () -> Unit,
    onOpenTranscript: (discourseID: String) -> Unit,
    onOpenSeries: (seriesID: String) -> Unit,
    modifier: Modifier = Modifier,
    onShowOutputSwitcher: (() -> Unit)? = null,
) {
    val viewModel = playerViewModel()
    val ui by viewModel.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    PlayerContent(
        ui = ui,
        viewModel = viewModel,
        onDismiss = onDismiss,
        onOpenTranscript = onOpenTranscript,
        onOpenSeries = onOpenSeries,
        onShowOutputSwitcher = onShowOutputSwitcher ?: { showSystemOutputSwitcher(context) },
        modifier = modifier,
    )
}

/** API 34's system output switcher; older releases have no public one, so Bluetooth settings. */
internal fun showSystemOutputSwitcher(context: Context) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE &&
        MediaRouter2.getInstance(context).showSystemOutputSwitcher()
    ) {
        return
    }
    runCatching {
        context.startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}

@Composable
private fun PlayerContent(
    ui: PlayerUiState,
    viewModel: PlayerViewModel,
    onDismiss: () -> Unit,
    onOpenTranscript: (String) -> Unit,
    onOpenSeries: (String) -> Unit,
    onShowOutputSwitcher: () -> Unit,
    modifier: Modifier,
) {
    var popover by rememberSaveable { mutableStateOf<PlayerPopover?>(null) }
    var popoverAnchor by remember { mutableStateOf<Rect?>(null) }
    var sheet by rememberSaveable { mutableStateOf<PlayerSheet?>(null) }
    var draft by remember { mutableStateOf<BookmarkDraft?>(null) }
    var toastTime by remember { mutableStateOf<Double?>(null) }
    var toastGeneration by remember { mutableIntStateOf(0) }
    var host by remember { mutableStateOf<LayoutCoordinates?>(null) }
    val anchors = remember { mutableMapOf<PlayerPopover, LayoutCoordinates>() }

    LaunchedEffect(toastGeneration) {
        if (toastTime == null) return@LaunchedEffect
        delay(2_000)
        toastTime = null
    }

    fun openPopover(kind: PlayerPopover) {
        val hostCoords = host
        val anchor = anchors[kind]
        popoverAnchor = if (hostCoords != null && anchor != null && anchor.isAttached) hostCoords.localBoundingBoxOf(anchor) else null
        popover = if (popover == kind) null else kind
    }

    ProvideElevatedSurfaces {
        Box(modifier.fillMaxSize().onGloballyPositioned { host = it }) {
            DismissibleLayer(onDismiss = onDismiss) { height, width ->
                PlayerColumn(
                    ui = ui,
                    viewModel = viewModel,
                    availableHeight = height,
                    availableWidth = width,
                    onOpenTranscript = { ui.player.currentTrackId?.let(onOpenTranscript) },
                    onOpenSeries = { ui.seriesID?.let(onOpenSeries) },
                    onShowOutputSwitcher = onShowOutputSwitcher,
                    onOpenQueue = { sheet = PlayerSheet.QUEUE },
                    onOpenDenoise = { sheet = PlayerSheet.DENOISE },
                    onSpeed = { openPopover(PlayerPopover.SPEED) },
                    onSleep = { openPopover(PlayerPopover.SLEEP) },
                    onBookmark = {
                        viewModel.bookmarkDraft()?.let {
                            draft = it
                            sheet = PlayerSheet.BOOKMARK
                        }
                    },
                    onAnchor = { kind, coords -> anchors[kind] = coords },
                )
            }

            BookmarkToast(toastTime)

            AnchoredPopover(
                visible = popover == PlayerPopover.SPEED,
                anchor = popoverAnchor.takeIf { popover == PlayerPopover.SPEED },
                onDismissRequest = { popover = null },
                width = if (LocalDensity.current.fontScale >= 1.6f) 320.dp else 300.dp,
                title = "Speed",
            ) {
                PlaybackSpeedControl(rate = ui.player.playbackRate, onRateChange = viewModel::setRate, onStep = viewModel::stepRate)
            }
            AnchoredPopover(
                visible = popover == PlayerPopover.SLEEP,
                anchor = popoverAnchor.takeIf { popover == PlayerPopover.SLEEP },
                onDismissRequest = { popover = null },
                width = 160.dp,
                title = "Sleep timer",
            ) {
                SleepTimerMenu(
                    state = ui.sleep,
                    onEndOfDiscourse = {
                        viewModel.sleepAtEndOfDiscourse()
                        popover = null
                    },
                    onMinutes = {
                        viewModel.startSleepTimer(it)
                        popover = null
                    },
                    onCancel = {
                        viewModel.cancelSleepTimer()
                        popover = null
                    },
                )
            }

            SheetHost(
                visible = sheet == PlayerSheet.QUEUE,
                onDismissRequest = { sheet = null },
                detents = listOf(SheetDetent.MEDIUM, SheetDetent.LARGE),
            ) {
                QueueSheetContent(
                    player = ui.player,
                    onSelect = {
                        viewModel.playQueueItem(it)
                        sheet = null
                    },
                    onDone = { sheet = null },
                )
            }
            SheetHost(
                visible = sheet == PlayerSheet.DENOISE,
                onDismissRequest = { sheet = null },
                showsDragIndicator = true,
                grouped = true,
            ) {
                DenoiseScreen(onDone = { sheet = null })
            }
            val currentDraft = draft
            SheetHost(
                visible = sheet == PlayerSheet.BOOKMARK && currentDraft != null,
                onDismissRequest = { sheet = null },
                detents = listOf(SheetDetent.MEDIUM),
                grouped = true,
            ) {
                if (currentDraft != null) {
                    AddBookmarkContent(
                        draft = currentDraft,
                        onCancel = { sheet = null },
                        onSave = { note, category, custom ->
                            viewModel.saveBookmark(currentDraft, note, category, custom)
                            sheet = null
                            toastTime = currentDraft.timestamp
                            toastGeneration++
                        },
                    )
                }
            }
        }
    }
}

/**
 * Follows the finger down from any point the content does not scroll, and dismisses past a
 * quarter of the height or on a downward fling, like the iOS sheet.
 */
@Composable
private fun DismissibleLayer(onDismiss: () -> Unit, content: @Composable (height: Dp, width: Dp) -> Unit) {
    val scope = rememberCoroutineScope()
    val dismiss by rememberUpdatedState(onDismiss)
    var offset by remember { mutableFloatStateOf(0f) }
    var settleJob by remember { mutableStateOf<Job?>(null) }
    var heightPx by remember { mutableFloatStateOf(1f) }
    var dismissed by remember { mutableStateOf(false) }

    fun dragBy(delta: Float): Float {
        settleJob?.cancel()
        val next = (offset + delta).coerceAtLeast(0f)
        val applied = next - offset
        offset = next
        return applied
    }

    fun release(velocity: Float) {
        if (offset <= 0f) return
        if (offset > heightPx * 0.25f || velocity > 1_500f) {
            // The host's exit slide carries the content on from where the finger left it.
            if (!dismissed) {
                dismissed = true
                dismiss()
            }
            return
        }
        settleJob = scope.launch { animate(offset, 0f, animationSpec = tween(250)) { v, _ -> offset = v } }
    }

    val connection = remember {
        object : NestedScrollConnection {
            override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset {
                if (source != NestedScrollSource.UserInput || available.y >= 0 || offset <= 0f) return Offset.Zero
                return Offset(0f, dragBy(available.y))
            }

            override fun onPostScroll(consumed: Offset, available: Offset, source: NestedScrollSource): Offset {
                if (source != NestedScrollSource.UserInput || available.y <= 0) return Offset.Zero
                return Offset(0f, dragBy(available.y))
            }

            override suspend fun onPreFling(available: Velocity): Velocity {
                if (offset <= 0f) return Velocity.Zero
                release(available.y)
                return available
            }
        }
    }

    val density = LocalDensity.current
    val corner = with(density) { (offset / 4f).coerceAtMost(28.dp.toPx()).toDp() }
    BoxWithConstraints(
        Modifier
            .fillMaxSize()
            .offset { IntOffset(0, offset.roundToInt()) }
            .clip(RoundedCornerShape(topStart = corner, topEnd = corner))
            .background(Osho.colors.systemBackground)
            .nestedScroll(connection),
    ) {
        heightPx = constraints.maxHeight.toFloat()
        val insets = with(density) {
            (WindowInsets.statusBars.getTop(this) + WindowInsets.navigationBars.getBottom(this)).toDp()
        }
        content(maxHeight - insets, maxWidth)
    }
}

@Composable
private fun PlayerColumn(
    ui: PlayerUiState,
    viewModel: PlayerViewModel,
    availableHeight: Dp,
    availableWidth: Dp,
    onOpenTranscript: () -> Unit,
    onOpenSeries: () -> Unit,
    onShowOutputSwitcher: () -> Unit,
    onOpenQueue: () -> Unit,
    onOpenDenoise: () -> Unit,
    onSpeed: () -> Unit,
    onSleep: () -> Unit,
    onBookmark: () -> Unit,
    onAnchor: (PlayerPopover, LayoutCoordinates) -> Unit,
) {
    val fontScale = LocalDensity.current.fontScale
    val side = if (availableWidth < 380.dp) 16.dp else 24.dp
    val tight = availableHeight < 700.dp
    // iOS @ScaledMetric artwork, capped by width and by a third of the height.
    val artwork = max(150.dp, min(min(280.dp * fontScale, availableWidth - 48.dp), availableHeight * 0.34f))
    val contentWidth = availableWidth - side * 2
    val playGlyph = max(44.dp, min(64.dp * fontScale, contentWidth * 0.18f))

    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .statusBarsPadding()
            .navigationBarsPadding()
            .padding(horizontal = side),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(
            Modifier
                .padding(top = 8.dp)
                .size(36.dp, 5.dp)
                .background(Osho.colors.secondaryLabel.copy(alpha = 0.5f), CircleShape)
                .clearAndSetSemantics {},
        )
        TopBar(ui, onShowOutputSwitcher, onOpenQueue, Modifier.padding(top = 8.dp))
        Spacer(Modifier.weight(1f))
        PortraitArtwork(
            size = artwork,
            cornerRadius = 16.dp,
            glow = true,
            modifier = Modifier.clickable(
                enabled = ui.hasTranscript,
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = onOpenTranscript,
            ),
        )
        Spacer(Modifier.weight(1f))
        TrackInfo(ui, onOpenSeries)
        ui.player.previousPosition?.let { previous ->
            BackToPill(previous, onClick = viewModel::returnToPreviousPosition, modifier = Modifier.padding(top = 12.dp))
        }
        SeekBar(ui, onSeek = viewModel::seekWithHistory, modifier = Modifier.padding(top = if (tight) 12.dp else 24.dp))
        Transport(ui, playGlyph, viewModel, Modifier.padding(top = if (tight) 12.dp else 24.dp))
        BottomControls(
            ui = ui,
            onSpeed = onSpeed,
            onDenoise = onOpenDenoise,
            onTranscript = onOpenTranscript,
            onSleep = onSleep,
            onBookmark = onBookmark,
            onAnchor = onAnchor,
            modifier = Modifier.padding(top = if (tight) 16.dp else 32.dp),
        )
        val issues = listOfNotNull(ui.denoiseIssue?.let { it to Osho.colors.systemOrange }, ui.player.error?.let { it.message to Osho.colors.systemRed })
        issues.forEach { (text, color) ->
            Text(
                text,
                style = Osho.typography.caption,
                color = color,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(top = 8.dp),
            )
        }
        Spacer(Modifier.weight(1f))
    }
}

@Composable
private fun TopBar(ui: PlayerUiState, onShowOutputSwitcher: () -> Unit, onOpenQueue: () -> Unit, modifier: Modifier) {
    val colors = Osho.colors
    Row(modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        PlainIconButton(
            icon = Icons.Outlined.SpeakerGroup,
            contentDescription = "AirPlay and output device",
            tint = colors.accent,
            onClick = onShowOutputSwitcher,
            iconSize = 24.dp,
        )
        Spacer(Modifier.weight(1f))
        PlainIconButton(
            icon = Icons.AutoMirrored.Rounded.FormatListBulleted,
            contentDescription = "Up Next",
            tint = colors.label,
            onClick = onOpenQueue,
            enabled = ui.isQueueBrowsable,
            onClickLabel = "show the playback queue",
            iconSize = 24.dp,
            modifier = Modifier.alpha(if (ui.isQueueBrowsable) 1f else DisabledAlpha),
        )
    }
}

@Composable
private fun PlainIconButton(
    icon: ImageVector,
    contentDescription: String,
    tint: Color,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    onClickLabel: String? = null,
    iconSize: Dp = 24.dp,
    boxSize: Dp = 44.dp,
) {
    Box(
        modifier
            .size(boxSize)
            .clickable(
                enabled = enabled,
                onClickLabel = onClickLabel,
                role = Role.Button,
                interactionSource = remember { MutableInteractionSource() },
                indication = ripple(bounded = false, radius = boxSize / 2),
                onClick = onClick,
            )
            .semantics { this.contentDescription = contentDescription },
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(iconSize))
    }
}

@Composable
private fun TrackInfo(ui: PlayerUiState, onOpenSeries: () -> Unit) {
    val colors = Osho.colors
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        val title = ui.title
        val linked = ui.seriesID != null
        Row(
            modifier = Modifier
                .then(
                    if (linked) {
                        Modifier
                            .clickable(
                                interactionSource = remember { MutableInteractionSource() },
                                indication = null,
                                role = Role.Button,
                                onClickLabel = "open the series",
                                onClick = onOpenSeries,
                            )
                            .semantics(mergeDescendants = true) { contentDescription = title }
                    } else {
                        Modifier
                    },
                ),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Center,
        ) {
            Text(
                title,
                style = Osho.typography.title3,
                fontWeight = FontWeight.Bold,
                color = colors.label,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                textAlign = TextAlign.Center,
                modifier = Modifier.weight(1f, fill = false).then(if (linked) Modifier.clearAndSetSemantics {} else Modifier),
            )
            if (linked) {
                Spacer(Modifier.width(4.dp))
                Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = colors.secondaryLabel, modifier = Modifier.size(18.dp))
            }
        }
        ui.subtitle?.let {
            ShrinkToFitText(it, style = Osho.typography.subheadline, color = colors.secondaryLabel, minScale = 0.85f)
        }
    }
}

@Composable
private fun BackToPill(previous: Double, onClick: () -> Unit, modifier: Modifier) {
    val accent = Osho.colors.accent
    Row(
        modifier = modifier
            .clip(CircleShape)
            .background(accent.copy(alpha = 0.15f))
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.AutoMirrored.Rounded.Undo, contentDescription = null, tint = accent, modifier = Modifier.size(14.dp))
        Text("Back to ${PlayerFormatting.time(previous)}", style = Osho.typography.caption, fontWeight = FontWeight.Medium, color = accent)
    }
}

@Composable
private fun SeekBar(ui: PlayerUiState, onSeek: (Double) -> Unit, modifier: Modifier) {
    val colors = Osho.colors
    val player = ui.player
    var scrubbing by remember { mutableStateOf(false) }
    var scrubTime by remember { mutableDoubleStateOf(0.0) }
    // Holds the released position until the player reports it, so the thumb does not snap back.
    var pendingSeek by remember { mutableStateOf<Double?>(null) }
    var showTotal by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(pendingSeek, player.currentTime) {
        val pending = pendingSeek ?: return@LaunchedEffect
        if (abs(player.currentTime - pending) < 1.5) {
            pendingSeek = null
        } else {
            delay(1_000)
            pendingSeek = null
        }
    }
    val shown = if (scrubbing) scrubTime else pendingSeek ?: player.currentTime
    val upper = maxOf(player.duration, 1.0)
    val timeStyle = Osho.typography.caption2.monospacedDigits()

    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(0.dp)) {
        IosSlider(
            value = shown.toFloat(),
            onValueChange = { scrubTime = it.toDouble() },
            valueRange = 0f..upper.toFloat(),
            onValueChangeStarted = {
                scrubTime = player.currentTime
                scrubbing = true
            },
            onValueChangeFinished = {
                onSeek(scrubTime)
                pendingSeek = scrubTime
                scrubbing = false
            },
            modifier = Modifier.semantics {
                contentDescription = "Playback position"
                stateDescription = "${PlayerFormatting.time(shown)} of ${PlayerFormatting.time(player.duration)}"
            },
        )
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(PlayerFormatting.time(shown), style = timeStyle, color = colors.secondaryLabel)
            Spacer(Modifier.weight(1f))
            val remaining = PlayerFormatting.time(maxOf(player.duration - shown, 0.0))
            Text(
                if (showTotal) PlayerFormatting.time(player.duration) else "-$remaining",
                style = timeStyle,
                color = colors.secondaryLabel,
                modifier = Modifier
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        onClick = { showTotal = !showTotal },
                    )
                    .clearAndSetSemantics {
                        contentDescription = if (showTotal) "Total time" else "Time remaining"
                        stateDescription = if (showTotal) PlayerFormatting.time(player.duration) else remaining
                        role = Role.Button
                        onClick(label = "switch between time remaining and total time") { showTotal = !showTotal; true }
                    },
            )
        }
    }
}

@Composable
private fun Transport(ui: PlayerUiState, playGlyph: Dp, viewModel: PlayerViewModel, modifier: Modifier) {
    val colors = Osho.colors
    val player = ui.player
    Row(modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
        TransportButton("Previous", enabled = ui.canGoPrevious, onClick = viewModel::skipToPrevious) { tint ->
            Icon(Icons.Rounded.FastRewind, contentDescription = null, tint = tint, modifier = Modifier.size(38.dp))
        }
        TransportButton("Skip back 15 seconds", onClick = viewModel::skipBackward) { tint ->
            SkipIntervalIcon(15, forward = false, tint = tint, size = 34.dp)
        }
        val playLabel = if (player.isPlaying) "Pause" else "Play"
        TransportButton(playLabel, onClick = viewModel::togglePlayPause) { tint ->
            Box(contentAlignment = Alignment.Center) {
                Icon(
                    if (player.isPlaying) Icons.Rounded.PauseCircle else Icons.Rounded.PlayCircle,
                    contentDescription = null,
                    tint = tint,
                    // SF circle glyphs draw a little inside their point size; Material's ring fills 20 of 24.
                    modifier = Modifier.size(playGlyph * 1.08f),
                )
                if (player.isBuffering) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(playGlyph + 8.dp).semantics { contentDescription = "Loading" },
                        color = colors.secondaryLabel,
                        strokeWidth = 2.dp,
                        trackColor = Color.Transparent,
                    )
                }
            }
        }
        TransportButton("Skip forward 30 seconds", onClick = viewModel::skipForward) { tint ->
            SkipIntervalIcon(30, forward = true, tint = tint, size = 34.dp)
        }
        TransportButton("Next", enabled = player.hasNext, onClick = viewModel::skipToNext) { tint ->
            Icon(Icons.Rounded.FastForward, contentDescription = null, tint = tint, modifier = Modifier.size(38.dp))
        }
    }
}

@Composable
private fun TransportButton(
    label: String,
    onClick: () -> Unit,
    enabled: Boolean = true,
    content: @Composable (tint: Color) -> Unit,
) {
    val colors = Osho.colors
    Box(
        Modifier
            .clickable(
                enabled = enabled,
                role = Role.Button,
                interactionSource = remember { MutableInteractionSource() },
                indication = ripple(bounded = false),
                onClick = onClick,
            )
            .semantics { contentDescription = label }
            .padding(3.dp),
        contentAlignment = Alignment.Center,
    ) {
        content(if (enabled) colors.label else colors.label.copy(alpha = 0.25f))
    }
}

@Composable
private fun BottomControls(
    ui: PlayerUiState,
    onSpeed: () -> Unit,
    onDenoise: () -> Unit,
    onTranscript: () -> Unit,
    onSleep: () -> Unit,
    onBookmark: () -> Unit,
    onAnchor: (PlayerPopover, LayoutCoordinates) -> Unit,
    modifier: Modifier,
) {
    val density = LocalDensity.current
    val rate = ui.player.playbackRate
    val sleep = ui.sleep
    val issue = ui.denoise.status.isIssue
    // Five short labels must fit one row, so text stops growing at xxxLarge as on iOS.
    CompositionLocalProvider(LocalDensity provides Density(density.density, density.fontScale.coerceAtMost(1.35f))) {
        Row(modifier.fillMaxWidth()) {
            ControlButton(
                icon = Icons.Outlined.Speed,
                label = PlaybackSpeed.label(rate),
                active = ui.isSpeedActive,
                description = "Playback speed",
                value = PlaybackSpeed.accessibilityLabel(rate),
                onClick = onSpeed,
                modifier = Modifier.onGloballyPositioned { onAnchor(PlayerPopover.SPEED, it) },
            )
            ControlButton(
                icon = if (issue) Icons.Outlined.WarningAmber else Icons.Rounded.GraphicEq,
                label = "DeNoise",
                active = ui.denoise.status.isActive,
                description = "DeNoise",
                value = ui.denoise.accessibilityValue,
                onClick = onDenoise,
                clickLabel = "adjust noise reduction, quiet speech and volume boost",
            )
            ControlButton(
                icon = Icons.Outlined.Description,
                label = "Transcript",
                active = false,
                description = "Transcript",
                value = null,
                onClick = onTranscript,
                enabled = ui.hasTranscript,
                clickLabel = "read along with the playing audio",
            )
            ControlButton(
                icon = if (sleep.isActive) Icons.Rounded.Bedtime else Icons.Outlined.Bedtime,
                label = sleep.statusLabel,
                active = sleep.isActive,
                description = "Sleep timer",
                value = if (sleep.isActive) sleep.statusLabel else "Off",
                onClick = onSleep,
                modifier = Modifier.onGloballyPositioned { onAnchor(PlayerPopover.SLEEP, it) },
            )
            ControlButton(
                icon = Icons.Outlined.BookmarkBorder,
                label = "Bookmark",
                active = false,
                description = "Add bookmark",
                value = null,
                onClick = onBookmark,
                clickLabel = "save the current position",
                enabled = ui.player.hasTrack,
                dimWhenDisabled = false,
            )
        }
    }
}

@Composable
private fun RowScope.ControlButton(
    icon: ImageVector,
    label: String,
    active: Boolean,
    description: String,
    value: String?,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    clickLabel: String? = null,
    dimWhenDisabled: Boolean = true,
) {
    val colors = Osho.colors
    val tint = if (active) colors.accent else colors.secondaryLabel
    Column(
        modifier = modifier
            .weight(1f)
            .alpha(if (!enabled && dimWhenDisabled) DisabledAlpha else 1f)
            .clickable(
                enabled = enabled,
                interactionSource = remember { MutableInteractionSource() },
                indication = ripple(bounded = false),
                onClick = onClick,
            )
            .clearAndSetSemantics {
                contentDescription = description
                if (value != null) stateDescription = value
                role = Role.Button
                if (!enabled) disabled()
                onClick(label = clickLabel) { if (enabled) onClick(); enabled }
            }
            .padding(vertical = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Box(Modifier.height(22.dp), contentAlignment = Alignment.Center) {
            Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(22.dp))
        }
        ShrinkToFitText(
            label,
            style = Osho.typography.caption2.copy(fontWeight = FontWeight.Medium),
            color = tint,
            minScale = 0.5f,
            modifier = Modifier.padding(horizontal = 4.dp),
        )
    }
}

@Composable
private fun BookmarkToast(time: Double?) {
    var last by remember { mutableDoubleStateOf(0.0) }
    if (time != null) last = time
    val top = with(LocalDensity.current) { WindowInsets.statusBars.getTop(this).toDp() } + 60.dp
    Box(Modifier.fillMaxWidth().padding(top = top), contentAlignment = Alignment.TopCenter) {
        AnimatedVisibility(
            visible = time != null,
            enter = slideInVertically(tween(300)) { -it * 3 } + fadeIn(tween(300)),
            exit = slideOutVertically(tween(300)) { -it * 3 } + fadeOut(tween(300)),
        ) {
            Text(
                "Bookmarked at ${PlayerFormatting.time(last)}",
                style = Osho.typography.subheadline,
                fontWeight = FontWeight.Medium,
                color = Osho.colors.label,
                modifier = Modifier
                    .glass(CircleShape)
                    .padding(horizontal = 16.dp, vertical = 10.dp),
            )
        }
    }
}
