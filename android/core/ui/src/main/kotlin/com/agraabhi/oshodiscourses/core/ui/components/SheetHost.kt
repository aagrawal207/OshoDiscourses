package com.agraabhi.oshodiscourses.core.ui.components

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.animation.core.animate
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.isImeVisible
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.Velocity
import androidx.compose.ui.unit.dp
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import com.agraabhi.oshodiscourses.core.ui.theme.ProvideElevatedSurfaces
import kotlin.math.abs
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/** iOS 26 sheet corners follow the display's radius. */
private val SheetCorner = 38.dp

/** How far a floating (medium) sheet sits inside the screen edges. */
private val SheetFloatInset = 8.dp

/** iOS presentation detents: about half the screen, or full height below the status bar. */
enum class SheetDetent { MEDIUM, LARGE }

/**
 * An iOS-style sheet drawn in the same window as the player, so it stacks over it, shares its
 * back handling and shows in screenshots. Drags and content overscroll resize or dismiss it.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun SheetHost(
    visible: Boolean,
    onDismissRequest: () -> Unit,
    modifier: Modifier = Modifier,
    detents: List<SheetDetent> = listOf(SheetDetent.LARGE),
    showsDragIndicator: Boolean = false,
    grouped: Boolean = false,
    content: @Composable () -> Unit,
) {
    val transition = remember { MutableTransitionState(false) }
    transition.targetState = visible
    if (!transition.currentState && !transition.targetState) return
    val dismiss by rememberUpdatedState(onDismissRequest)
    BackHandler(enabled = visible) { dismiss() }

    Box(modifier.fillMaxSize()) {
        AnimatedVisibility(transition, enter = fadeIn(tween(250)), exit = fadeOut(tween(250))) {
            Box(
                Modifier
                    .fillMaxSize()
                    .background(Color.Black.copy(alpha = 0.15f))
                    .clearAndSetSemantics {}
                    .pointerInput(Unit) { detectTapGestures { dismiss() } },
            )
        }
        BoxWithConstraints(Modifier.fillMaxSize().imePadding()) {
            val density = LocalDensity.current
            val topGap = with(density) { WindowInsets.statusBars.getTop(this) + 10.dp.roundToPx() }
            val available = constraints.maxHeight.toFloat()
            val large = (available - topGap).coerceAtLeast(0f)
            // iOS grows a sheet to full height while the keyboard is up, so its fields stay in view.
            val keyboard = WindowInsets.isImeVisible
            val heights = detents.sorted().map { if (it == SheetDetent.LARGE || keyboard) large else minOf(large, available * 0.5f) }
            AnimatedVisibility(
                transition,
                modifier = Modifier.align(Alignment.BottomCenter),
                enter = slideInVertically(tween(350)) { it },
                exit = slideOutVertically(tween(300)) { it },
            ) {
                SheetSurface(
                    heights = heights,
                    visible = visible,
                    showsDragIndicator = showsDragIndicator,
                    grouped = grouped,
                    floats = detents.min() == SheetDetent.MEDIUM,
                    onDismiss = { dismiss() },
                    content = content,
                )
            }
        }
    }
}

@Composable
private fun SheetSurface(
    heights: List<Float>,
    visible: Boolean,
    showsDragIndicator: Boolean,
    grouped: Boolean,
    floats: Boolean,
    onDismiss: () -> Unit,
    content: @Composable () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var detent by remember { mutableIntStateOf(0) }
    // Positive when dragged down from the current detent.
    var offset by remember { mutableFloatStateOf(0f) }
    var settleJob by remember { mutableStateOf<Job?>(null) }
    LaunchedEffect(visible) {
        if (visible) {
            detent = 0
            offset = 0f
        }
    }
    val minHeight = heights.first()
    val maxHeight = heights.last()
    val visibleHeight = heights[detent.coerceIn(heights.indices)] - offset
    val sheetHeight = visibleHeight.coerceIn(minHeight, maxHeight)
    val translation = (minHeight - visibleHeight).coerceAtLeast(0f)

    fun dragBy(delta: Float): Float {
        settleJob?.cancel()
        val current = heights[detent] - offset
        val target = (current - delta).coerceAtMost(maxHeight)
        val applied = current - target
        offset += applied
        return applied
    }

    fun settle(velocity: Float) {
        val current = heights[detent] - offset
        val projected = current - velocity * 0.15f
        if (projected < minHeight * 0.6f || (velocity > 2_000f && current < minHeight)) {
            onDismiss()
            return
        }
        val target = heights.indices.minBy { abs(heights[it] - projected) }
        detent = target
        val start = heights[target] - current
        settleJob = scope.launch { animate(start, 0f, animationSpec = tween(250)) { v, _ -> offset = v } }
    }

    val connection = remember(heights) {
        object : NestedScrollConnection {
            override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset {
                if (source != NestedScrollSource.UserInput) return Offset.Zero
                // A finger moving up grows the sheet before the content scrolls, as iOS does.
                if (available.y < 0 && heights[detent] - offset < maxHeight) return Offset(0f, dragBy(available.y))
                return Offset.Zero
            }

            override fun onPostScroll(consumed: Offset, available: Offset, source: NestedScrollSource): Offset {
                if (source != NestedScrollSource.UserInput || available.y <= 0) return Offset.Zero
                return Offset(0f, dragBy(available.y))
            }

            override suspend fun onPreFling(available: Velocity): Velocity {
                if (offset == 0f) return Velocity.Zero
                settle(available.y)
                return available
            }
        }
    }

    val density = LocalDensity.current
    // iOS 26 floats a medium sheet inside the screen edges and docks it once dragged to full height.
    val progress = if (maxHeight > minHeight) ((sheetHeight - minHeight) / (maxHeight - minHeight)).coerceIn(0f, 1f) else 0f
    val inset = if (floats) SheetFloatInset * (1f - progress) else 0.dp
    val bottomCorner = if (floats) SheetCorner * (1f - progress) else 0.dp
    ProvideElevatedSurfaces {
        val colors = Osho.colors
        Column(
            Modifier
                .padding(start = inset, end = inset, bottom = inset)
                .fillMaxWidth()
                .height(with(density) { sheetHeight.toDp() })
                .graphicsLayer { translationY = translation }
                .clip(RoundedCornerShape(topStart = SheetCorner, topEnd = SheetCorner, bottomStart = bottomCorner, bottomEnd = bottomCorner))
                .background(if (grouped) colors.systemGroupedBackground else colors.systemBackground)
                .consumeWindowInsets(WindowInsets.statusBars)
                .nestedScroll(connection)
                .draggable(
                    orientation = Orientation.Vertical,
                    state = rememberDraggableState { dragBy(it) },
                    onDragStopped = { settle(it) },
                ),
        ) {
            if (showsDragIndicator) {
                Box(Modifier.fillMaxWidth().padding(top = 5.dp).clearAndSetSemantics {}, contentAlignment = Alignment.Center) {
                    Box(Modifier.size(36.dp, 5.dp).background(colors.secondaryLabel.copy(alpha = 0.5f), CircleShape))
                }
            }
            Box(Modifier.weight(1f)) { content() }
        }
    }
}
