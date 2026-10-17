package com.agraabhi.oshodiscourses.core.ui.components

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.agraabhi.oshodiscourses.core.ui.theme.Osho
import com.agraabhi.oshodiscourses.core.ui.theme.ProvideElevatedSurfaces
import kotlin.math.roundToInt

/**
 * iOS `.popover` kept as a popover on iPhone (ui-style.md §8): a card above [anchor], which is
 * in this host's coordinates. Drawn in-window so it layers with the player and its sheets.
 */
@Composable
fun AnchoredPopover(
    visible: Boolean,
    anchor: Rect?,
    onDismissRequest: () -> Unit,
    width: Dp,
    title: String,
    content: @Composable () -> Unit,
) {
    val transition = remember { MutableTransitionState(false) }
    transition.targetState = visible && anchor != null
    // The card keeps its place while it fades out after the anchor is cleared.
    var lastAnchor by remember { mutableStateOf(Rect.Zero) }
    if (anchor != null) lastAnchor = anchor
    if (!transition.currentState && !transition.targetState) return
    val dismiss by rememberUpdatedState(onDismissRequest)
    BackHandler(enabled = visible) { dismiss() }

    Box(Modifier.fillMaxSize()) {
        if (visible) {
            Box(Modifier.fillMaxSize().clearAndSetSemantics {}.pointerInput(Unit) { detectTapGestures { dismiss() } })
        }
        val shape = RoundedCornerShape(20.dp)
        val statusTop = WindowInsets.statusBars.getTop(LocalDensity.current)
        Layout(
            content = {
                AnimatedVisibility(
                    transition,
                    enter = fadeIn(tween(200)) + scaleIn(tween(200), initialScale = 0.85f, transformOrigin = TransformOrigin(0.5f, 1f)),
                    exit = fadeOut(tween(150)) + scaleOut(tween(150), targetScale = 0.9f, transformOrigin = TransformOrigin(0.5f, 1f)),
                ) {
                    ProvideElevatedSurfaces {
                        Box(
                            Modifier
                                .width(width)
                                .shadow(24.dp, shape, ambientColor = Color.Black.copy(alpha = 0.2f), spotColor = Color.Black.copy(alpha = 0.2f))
                                .clip(shape)
                                .background(Osho.colors.secondarySystemGroupedBackground)
                                .semantics { paneTitle = title },
                        ) { content() }
                    }
                }
            },
        ) { measurables, constraints ->
            val loose = constraints.copy(minWidth = 0, minHeight = 0)
            val placeable = measurables.firstOrNull()?.measure(loose)
            layout(constraints.maxWidth, constraints.maxHeight) {
                if (placeable == null) return@layout
                val margin = 8.dp.roundToPx()
                val gap = 6.dp.roundToPx()
                val top = statusTop + margin
                val x = (lastAnchor.center.x - placeable.width / 2f).roundToInt()
                    .coerceIn(margin, (constraints.maxWidth - placeable.width - margin).coerceAtLeast(margin))
                val above = lastAnchor.top.roundToInt() - gap - placeable.height
                val y = if (above >= top) above else (lastAnchor.bottom.roundToInt() + gap).coerceAtMost(constraints.maxHeight - placeable.height)
                placeable.place(x, y.coerceAtLeast(0))
            }
        }
    }
}
